import Metal
import simd

/// The paint a loaded brush carries, and what happens to it as the brush goes. See the
/// loaded-brush section of Shaders.metal.
///
/// Settled dabs are drawn from the carry in groups; every quarter diameter of path the
/// carry is brought up to date for the dab there, after that group is drawn, so the
/// transfer reads the paint the dabs have laid. Where the groups end depends only on path
/// distance, never on which frame a dab arrived in, so a stroke comes out the same however
/// its samples fell into frames. One carry per symmetry copy; they last for a stroke.
final class LoadedBrushRenderer {
    private let context: MetalContext
    /// Edge of the square carry textures. A larger brush is carried at lower resolution.
    static let carrySize = 256
    /// The carry is brought up to date every this many diameters of path.
    static let updateSpacing: Float = 0.25

    private(set) var carries: [MTLTexture] = []
    private(set) var texels = SIMD2<Float>(1, 1)
    private var filled = false
    /// Path distance of the last transfer.
    private var updatedAt: Float = 0
    /// The last dab drawn since then: the next transfer is for it, once the path has gone a
    /// quarter diameter past the last one.
    private var pending: Dab?

    init(context: MetalContext) {
        self.context = context
    }

    /// Start afresh: the next dab fills the carry. Call at pen-down.
    func beginStroke() {
        filled = false
        pending = nil
        updatedAt = 0
    }

    /// The carries as they stand, for drawing the tail from; nil before the first dab.
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
    }

    /// Draw settled `dabs` into `strokeTexture`, in order, one copy per entry in `mirrors`,
    /// from the carry, bringing the carry up to date along the way.
    ///
    /// - Parameters:
    ///   - brushSize: the brush's full size, which sets the carry's resolution for the stroke.
    ///   - opacityScale: multiplies every dab's opacity.
    ///   - layer: what the brush picks up from: the paint there before this stroke.
    /// - Returns: the canvas-space bounds of each copy.
    func encode(
        dabs: [Dab],
        brush: BrushDescriptor,
        settings: StampSettings,
        load: StampSettings.Load,
        color: StrokeColor,
        brushSize: Float,
        opacityScale: Float,
        mirrors: [(CGPoint) -> CGPoint],
        strokeTexture: MTLTexture,
        layer: MTLTexture,
        height: MTLTexture? = nil,
        heightOpacity: Float = 1,
        strokeRenderer: StrokeRenderer,
        commandBuffer: MTLCommandBuffer,
        canvasSize: CGSize
    ) -> [CGRect] {
        guard !dabs.isEmpty, let paper = context.brushTextures.paperGrain else { return [] }
        while carries.count < mirrors.count {
            guard let texture = makeCarry() else { return [] }
            carries.append(texture)
        }
        let tip = context.brushTextures.tipTexture(for: settings.tip)
        let tipTexture = tip ?? paper
        let tipIsTexture: Int32 = tip == nil ? 0 : 1
        let aspect = max(dabs[0].aspect, 1)
        var params = Params(
            center: .zero, size: 0, angle: 0, aspect: 1,
            canvasSize: SIMD2(Float(canvasSize.width), Float(canvasSize.height)),
            carryTexels: texels, hardness: brush.hardness, tipIsTexture: tipIsTexture,
            press: 0, depletion: 0, bleed: 0, resaturation: 0,
            color: SIMD4(color.red, color.green, color.blue, load.amount * color.alpha),
            // The loading pattern belongs to the brush, like its grain: the same every stroke
            variation: load.variation, seed: 0.37, mixPigments: brush.mixing == .pigment ? 1 : 0
        )

        if !filled {
            // A texel per canvas pixel of the brush at its full size, up to the carry's own
            texels = SIMD2(min(Float(Self.carrySize), max(8, (brushSize * aspect).rounded(.up))),
                           min(Float(Self.carrySize), max(8, brushSize.rounded(.up))))
            params.carryTexels = texels
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
            updatedAt = dabs[0].pathDistance
        }
        params.carryTexels = texels
        let inUse = StrokeRenderer.Carries(textures: Array(carries.prefix(mirrors.count)), texels: texels)

        var bounds = [CGRect](repeating: .null, count: mirrors.count)
        var group: [Dab] = []

        func drawGroup() {
            guard !group.isEmpty else { return }
            let pass = MTLRenderPassDescriptor()
            pass.colorAttachments[0].texture = strokeTexture
            pass.colorAttachments[0].loadAction = .load
            pass.colorAttachments[0].storeAction = .store
            guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: pass) else { return }
            let drawn = strokeRenderer.encode(dabs: group, brush: brush, settings: settings, color: color,
                                              opacityScale: opacityScale, mirrors: mirrors, carries: inUse,
                                              encoder: encoder, canvasSize: canvasSize)
            encoder.endEncoding()
            for (index, rect) in drawn.enumerated() where index < bounds.count { bounds[index] = bounds[index].union(rect) }
            // The same dabs as thickness, from the same state of the carry
            if let height {
                let heightPass = MTLRenderPassDescriptor()
                heightPass.colorAttachments[0].texture = height
                heightPass.colorAttachments[0].loadAction = .load
                heightPass.colorAttachments[0].storeAction = .store
                if let heightEncoder = commandBuffer.makeRenderCommandEncoder(descriptor: heightPass) {
                    strokeRenderer.encodeHeight(dabs: group, brush: brush, settings: settings, opacityScale: heightOpacity,
                                                mirrors: mirrors, carries: inUse, encoder: heightEncoder, canvasSize: canvasSize)
                    heightEncoder.endEncoding()
                }
            }
            group.removeAll(keepingCapacity: true)
        }

        func transfer(for dab: Dab) {
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
            updatedAt = dab.pathDistance
        }

        for dab in dabs {
            if let last = pending, dab.pathDistance > updatedAt + Self.updateSpacing * last.size {
                // The path has gone a quarter diameter past the last transfer: the carry
                // catches up with the last dab drawn before this one
                drawGroup()
                transfer(for: last)
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
