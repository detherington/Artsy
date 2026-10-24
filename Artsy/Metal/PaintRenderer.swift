import Metal
import simd

/// Paint brushes with something to do between dabs: a loaded brush's carry (see the
/// loaded-brush section of Shaders.metal) and thick paint's push (its own section).
///
/// Settled dabs go through in groups of a quarter diameter of path. For each group, in
/// order: each dab pushes the paint already under it out to its rim, the group's colour is
/// drawn from the carry (a loaded brush), its thickness is laid, and then the carry is
/// brought up to date for the last dab. Where the groups end depends only on path
/// distance, never on which frame a dab arrived in, so a stroke comes out the same however
/// its samples fell into frames. One carry per symmetry copy; they last for a stroke.
final class PaintRenderer {
    private let context: MetalContext
    /// Edge of the square carry textures. A larger brush is carried at lower resolution.
    static let carrySize = 256
    /// The carry is brought up to date every this many diameters of path.
    static let updateSpacing: Float = 0.25

    private(set) var carries: [MTLTexture] = []
    private(set) var texels = SIMD2<Float>(1, 1)
    private var filled = false
    /// Path distance of the last transfer (or group end, for a brush without a carry).
    private var updatedAt: Float = 0
    /// The last dab drawn since then: the next transfer is for it, once the path has gone a
    /// quarter diameter past the last one.
    private var pending: Dab?
    private let pusher: ImpastoPusher

    init(context: MetalContext) {
        self.context = context
        pusher = ImpastoPusher(context: context)
    }

    /// Start afresh: the next dab fills the carry. Call at pen-down.
    func beginStroke() {
        filled = false
        pending = nil
        updatedAt = 0
    }

    /// The carries as they stand, for drawing the tail from; nil before the first dab, or
    /// for a brush without a load.
    var carriesInUse: StrokeRenderer.Carries? {
        filled ? StrokeRenderer.Carries(textures: carries, texels: texels) : nil
    }

    /// Mirrors `LoadedBrushParams` in Shaders.metal.
    private struct Params {
        var center: SIMD2<Float>
        var size: Float
        var angle: Float
        var aspect: Float
        var canvasSize: SIMD2<Float>
        var carryTexels: SIMD2<Float>
        var hardness: Float
        var tipIsTexture: Int32
        var press: Float
        var depletion: Float
        var bleed: Float
        var resaturation: Float
        var color: SIMD4<Float>
        var variation: Float
        var seed: Float
        var mixPigments: Int32
        var usesWet: Int32
        var wetNow: Float
        var dryingTime: Float
        var bristleCount: Int32
    }

    /// Draw settled `dabs`, in order, one copy per entry in `mirrors`: the colour into
    /// `strokeTexture` for a loaded brush (`load`), the thickness into `height` for a thick
    /// one, pushing the paint under each dab first.
    ///
    /// - Parameters:
    ///   - brushSize: the brush's full size, which sets the carry's resolution for the stroke.
    ///   - opacityScale: multiplies every dab's opacity.
    ///   - layer: what a loaded brush picks up from: the paint there before this stroke.
    ///   - wet: the layer's wet map, read at `wetNow` seconds since its epoch; only wet
    ///     paint comes up. Nil for a layer that has none: all of it is dry.
    ///   - heightOpacity: scales the thickness laid (a wash's opacity applies at the merge,
    ///     so thinned paint piles less).
    /// - Returns: the canvas-space bounds of each copy, over colour and height alike.
    func encode(
        dabs: [Dab],
        brush: BrushDescriptor,
        settings: StampSettings,
        load: StampSettings.Load?,
        color: StrokeColor,
        brushSize: Float,
        opacityScale: Float,
        mirrors: [(CGPoint) -> CGPoint],
        strokeTexture: MTLTexture,
        layer: MTLTexture,
        wet: MTLTexture? = nil,
        wetNow: Float = 0,
        dryingTime: Float = 1,
        height: MTLTexture? = nil,
        heightOpacity: Float = 1,
        strokeRenderer: StrokeRenderer,
        commandBuffer: MTLCommandBuffer,
        canvasSize: CGSize
    ) -> [CGRect] {
        guard !dabs.isEmpty, let paper = context.brushTextures.paperGrain else { return [] }
        let tip = context.brushTextures.tipTexture(for: settings.tip)
        let tipTexture = tip ?? paper
        let tipIsTexture: Int32 = tip == nil ? 0 : 1
        let aspect = max(dabs[0].aspect, 1)
        let impasto = settings.impasto
        let pushes = (impasto?.squeeze ?? 0) > 0 && height != nil
        let share = ImpastoPusher.share(squeeze: impasto?.squeeze ?? 0, spacing: settings.spacing)
        let lays = (impasto?.thickness ?? 0) > 0 && height != nil

        var params = Params(
            center: .zero, size: 0, angle: 0, aspect: 1,
            canvasSize: SIMD2(Float(canvasSize.width), Float(canvasSize.height)),
            carryTexels: texels, hardness: brush.hardness, tipIsTexture: tipIsTexture,
            press: 0, depletion: 0, bleed: 0, resaturation: 0,
            color: SIMD4(color.red, color.green, color.blue, (load?.amount ?? 1) * color.alpha),
            // The loading pattern belongs to the brush, like its grain: the same every stroke
            variation: load?.variation ?? 0, seed: 0.37, mixPigments: brush.mixing == .pigment ? 1 : 0,
            usesWet: wet == nil ? 0 : 1, wetNow: wetNow, dryingTime: dryingTime,
            bristleCount: Int32(settings.bristles?.count ?? 0)
        )

        if let load, !filled {
            while carries.count < mirrors.count {
                guard let texture = makeCarry() else { return [] }
                carries.append(texture)
            }
            // A texel per canvas pixel of the brush at its full size, up to the carry's own
            texels = SIMD2(min(Float(Self.carrySize), max(8, (brushSize * aspect).rounded(.up))),
                           min(Float(Self.carrySize), max(8, brushSize.rounded(.up))))
            params.carryTexels = texels
            params.variation = load.variation
            let bristles = context.brushTextures.grainTexture(for: .bristles) ?? paper
            guard let encoder = commandBuffer.makeComputeCommandEncoder() else { return [] }
            encoder.setComputePipelineState(context.loadedBrushFillPipelineState)
            encoder.setTexture(bristles, index: 1)
            encoder.setSamplerState(context.grainSampler, index: 0)
            for (index, carry) in carries.enumerated() where index < mirrors.count {
                encoder.setTexture(carry, index: 0)
                encoder.setBytes(&params, length: MemoryLayout<Params>.stride, index: 0)
                encoder.dispatchThreads(MTLSize(width: Int(texels.x), height: Int(texels.y), depth: 1),
                                        threadsPerThreadgroup: MTLSize(width: 16, height: 16, depth: 1))
            }
            encoder.endEncoding()
            filled = true
        }
        if pending == nil { updatedAt = dabs[0].pathDistance }
        params.carryTexels = texels
        let inUse: StrokeRenderer.Carries? = load == nil ? nil
            : StrokeRenderer.Carries(textures: Array(carries.prefix(mirrors.count)), texels: texels)

        var bounds = [CGRect](repeating: .null, count: mirrors.count)
        var group: [Dab] = []

        func drawGroup() {
            guard !group.isEmpty else { return }
            // 1. The group's colour, from the carry
            if let inUse {
                let pass = MTLRenderPassDescriptor()
                pass.colorAttachments[0].texture = strokeTexture
                pass.colorAttachments[0].loadAction = .load
                pass.colorAttachments[0].storeAction = .store
                if let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: pass) {
                    strokeRenderer.encode(dabs: group, brush: brush, settings: settings, color: color,
                                          opacityScale: opacityScale, mirrors: mirrors, carries: inUse,
                                          encoder: encoder, canvasSize: canvasSize)
                    encoder.endEncoding()
                }
            }
            // 2. Its thickness, dab by dab: each pushes the paint already under it, the dab
            // before it included, and then lays its own, from the same state of the carry.
            // One dab at a time so the result is the same however the dabs fell into frames.
            if let height, pushes || lays {
                for dab in group {
                    if pushes {
                        pusher.push(dab, press: dab.opacity * opacityScale, squeeze: share, brush: brush,
                                    tip: tipTexture, tipIsTexture: tipIsTexture, bristleCount: settings.bristles?.count ?? 0,
                                    mirrors: mirrors, height: height, commandBuffer: commandBuffer, canvasSize: canvasSize)
                    }
                    if lays {
                        let pass = MTLRenderPassDescriptor()
                        pass.colorAttachments[0].texture = height
                        pass.colorAttachments[0].loadAction = .load
                        pass.colorAttachments[0].storeAction = .store
                        if let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: pass) {
                            strokeRenderer.encodeHeight(dabs: [dab], brush: brush, settings: settings, opacityScale: heightOpacity,
                                                        mirrors: mirrors, carries: inUse, encoder: encoder, canvasSize: canvasSize)
                            encoder.endEncoding()
                        }
                    }
                }
            }
            // What all of that touched: the dabs, and the band a push reaches beyond them
            let margin: CGFloat = pushes ? 1 + 2 * CGFloat(ImpastoPusher.band) : 1
            for (index, mirror) in mirrors.enumerated() {
                for dab in group {
                    let center = mirror(dab.center)
                    let reach = CGFloat(dab.size * max(dab.aspect, 1)) * 0.7072 * margin
                    bounds[index] = bounds[index].union(CGRect(x: center.x - reach, y: center.y - reach, width: reach * 2, height: reach * 2))
                }
            }
            group.removeAll(keepingCapacity: true)
        }

        func transfer(for dab: Dab, load: StampSettings.Load) {
            // Shares defined per diameter, taken for the path travelled since the last transfer
            let step = max(0, dab.pathDistance - updatedAt) / max(dab.size, 1)
            params.press = dab.opacity * opacityScale
            params.depletion = 1 - pow(1 - min(load.depletion, 1), step)
            params.bleed = 1 - pow(1 - min(load.bleed, 1), step)
            params.resaturation = 1 - pow(1 - min(load.resaturation, 1), step)
            params.size = dab.size
            params.aspect = dab.aspect
            guard let encoder = commandBuffer.makeComputeCommandEncoder() else { return }
            encoder.setComputePipelineState(context.loadedBrushTransferPipelineState)
            encoder.setTexture(layer, index: 1)
            encoder.setTexture(tipTexture, index: 2)
            encoder.setTexture(wet ?? layer, index: 3)
            encoder.setSamplerState(context.linearSampler, index: 0)
            encoder.setSamplerState(context.tipSampler, index: 1)
            for (index, mirror) in mirrors.enumerated() where index < carries.count {
                let center = mirror(dab.center)
                // A mirror turns the tip as well as moving it, as the dabs are drawn
                let ahead = mirror(CGPoint(x: dab.center.x + CGFloat(cos(dab.angle)),
                                           y: dab.center.y + CGFloat(sin(dab.angle))))
                params.center = SIMD2(Float(center.x), Float(center.y))
                params.angle = Float(atan2(ahead.y - center.y, ahead.x - center.x))
                encoder.setTexture(carries[index], index: 0)
                encoder.setBytes(&params, length: MemoryLayout<Params>.stride, index: 0)
                encoder.dispatchThreads(MTLSize(width: Int(texels.x), height: Int(texels.y), depth: 1),
                                        threadsPerThreadgroup: MTLSize(width: 16, height: 16, depth: 1))
            }
            encoder.endEncoding()
        }

        for dab in dabs {
            if let last = pending, dab.pathDistance > updatedAt + Self.updateSpacing * last.size {
                // The path has gone a quarter diameter past the last update: this group is
                // drawn, and the carry catches up with the last dab drawn before this one
                drawGroup()
                if let load { transfer(for: last, load: load) }
                updatedAt = last.pathDistance
            }
            group.append(dab)
            pending = dab
        }
        drawGroup()
        return bounds
    }

    private func makeCarry() -> MTLTexture? {
        let desc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba16Float, width: Self.carrySize, height: Self.carrySize, mipmapped: false
        )
        desc.usage = [.shaderRead, .shaderWrite]
        desc.storageMode = .private
        let texture = context.device.makeTexture(descriptor: desc)
        texture?.label = "Loaded brush carry"
        return texture
    }
}

/// Pushes the paint under a dab out to its rim, on a layer's height map. See the
/// thick-paint section of Shaders.metal. Shared by the paint and smudge renderers, each
/// with its own.
final class ImpastoPusher {
    private let context: MetalContext
    /// A copy of the patch of the height map under a dab, for the push to read while it writes.
    private var backdrop: MTLTexture?
    /// The band outside the tip that pushed paint lands in, as a fraction of the dab's size.
    static let band: Float = 0.3
    /// How much more of it goes ahead of the brush than behind, 0...1.
    static let forward: Float = 0.6

    init(context: MetalContext) {
        self.context = context
    }

    /// The share of the paint under one dab that it pushes out, for a brush whose `squeeze`
    /// is the share pushed per diameter of path: dabs overlap `1 / spacing` times over, and
    /// a spot under the brush is pushed by each, so the result is the same at any spacing.
    static func share(squeeze: Float, spacing: Float) -> Float {
        1 - pow(1 - min(max(squeeze, 0), 1), max(spacing, 0.01))
    }

    /// Mirrors `ImpastoPushParams` in Shaders.metal.
    private struct Params {
        var center: SIMD2<Float>
        var size: Float
        var angle: Float
        var aspect: Float
        var canvasSize: SIMD2<Float>
        var patchOrigin: SIMD2<UInt32>
        var patchSize: SIMD2<UInt32>
        var hardness: Float
        var tipIsTexture: Int32
        var press: Float
        var squeeze: Float
        var heading: SIMD2<Float>
        var forward: Float
        var band: Float
        var bristleCount: Int32
        var fan: Float
        var gap: Float
    }

    /// Push the paint under `dab`, one copy per entry in `mirrors`.
    /// - Parameter squeeze: the share of it this dab pushes out (see `share(squeeze:spacing:)`).
    func push(_ dab: Dab, press: Float, squeeze: Float, brush: BrushDescriptor, tip: MTLTexture, tipIsTexture: Int32,
              bristleCount: Int = 0, mirrors: [(CGPoint) -> CGPoint], height: MTLTexture, commandBuffer: MTLCommandBuffer,
              canvasSize: CGSize) {
        var params = Params(
            center: .zero, size: dab.size, angle: 0, aspect: dab.aspect,
            canvasSize: SIMD2(Float(canvasSize.width), Float(canvasSize.height)),
            patchOrigin: .zero, patchSize: .zero,
            hardness: brush.hardness, tipIsTexture: tipIsTexture, press: min(press, 1), squeeze: min(squeeze, 1),
            heading: .zero, forward: Self.forward, band: Self.band,
            bristleCount: Int32(bristleCount), fan: dab.fan, gap: dab.gap
        )
        let reach = CGFloat(dab.size * max(dab.aspect, 1)) * 0.7072 * CGFloat(1 + 2 * Self.band) + 2
        for mirror in mirrors {
            let center = mirror(dab.center)
            let ahead = mirror(CGPoint(x: dab.center.x + CGFloat(cos(dab.angle)), y: dab.center.y + CGFloat(sin(dab.angle))))
            let going = mirror(CGPoint(x: dab.center.x + CGFloat(cos(dab.heading)), y: dab.center.y + CGFloat(sin(dab.heading))))
            params.center = SIMD2(Float(center.x), Float(center.y))
            params.angle = Float(atan2(ahead.y - center.y, ahead.x - center.x))
            let heading = SIMD2(Float(going.x - center.x), Float(going.y - center.y))
            params.heading = simd_length(heading) > 0 ? simd_normalize(heading) : .zero

            // The patch of the height map under the dab and its band, copied for the kernel to read
            let width = height.width, h = height.height
            let minX = max(0, Int((center.x - reach).rounded(.down)))
            let maxX = min(width, Int((center.x + reach).rounded(.up)))
            let minY = max(0, h - Int((center.y + reach).rounded(.up)))
            let maxY = min(h, h - Int((center.y - reach).rounded(.down)))
            guard maxX > minX, maxY > minY else { continue }
            let patch = MTLScissorRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
            if backdrop == nil || backdrop!.width < patch.width || backdrop!.height < patch.height {
                let side = 256 << (0...8).first { patch.width <= 256 << $0 && patch.height <= 256 << $0 }!
                let desc = MTLTextureDescriptor.texture2DDescriptor(
                    pixelFormat: .r16Float, width: min(side, max(width, patch.width)),
                    height: min(side, max(h, patch.height)), mipmapped: false
                )
                desc.usage = [.shaderRead]
                desc.storageMode = .private
                backdrop = context.device.makeTexture(descriptor: desc)
                backdrop?.label = "Push backdrop"
            }
            guard let backdrop, let blit = commandBuffer.makeBlitCommandEncoder() else { return }
            blit.copy(from: height, sourceSlice: 0, sourceLevel: 0,
                      sourceOrigin: MTLOrigin(x: patch.x, y: patch.y, z: 0),
                      sourceSize: MTLSize(width: patch.width, height: patch.height, depth: 1),
                      to: backdrop, destinationSlice: 0, destinationLevel: 0, destinationOrigin: MTLOrigin(x: 0, y: 0, z: 0))
            blit.endEncoding()

            params.patchOrigin = SIMD2(UInt32(patch.x), UInt32(patch.y))
            params.patchSize = SIMD2(UInt32(patch.width), UInt32(patch.height))
            guard let encoder = commandBuffer.makeComputeCommandEncoder() else { return }
            encoder.setComputePipelineState(context.impastoPushPipelineState)
            encoder.setTexture(height, index: 0)
            encoder.setTexture(backdrop, index: 1)
            encoder.setTexture(tip, index: 2)
            encoder.setSamplerState(context.tipSampler, index: 0)
            encoder.setBytes(&params, length: MemoryLayout<Params>.stride, index: 0)
            encoder.dispatchThreads(MTLSize(width: patch.width, height: patch.height, depth: 1),
                                    threadsPerThreadgroup: MTLSize(width: 16, height: 16, depth: 1))
            encoder.endEncoding()
        }
    }
}
