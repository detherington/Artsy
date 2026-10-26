import Metal
import simd

/// Water on the move on one layer: the state of the flow, on a rectangle of the layer that
/// has had water laid on it. See the water section of Shaders.metal.
///
/// The layer's own pixels always show the look — the dry paint with the pigment still in
/// the water glazed over it — so everything that reads a layer (the composite, thumbnails,
/// saving, export, undo) sees what the painter sees. The dry paint is kept aside here and
/// the look rewritten after every step; when something else writes the layer's pixels the
/// flow is settled (`Layer.settleWater()`): the look stands, and the water is forgotten.
public final class LayerWater {
    /// Layer pixels per texel: 1, or 2 on a canvas too big to run full size.
    let scale: Int
    /// The rectangle of the layer the water is on, in layer pixels (origin top-left), a
    /// multiple of `scale` on every side.
    private(set) var region: MTLScissorRect
    /// Free water per texel and how wet the paper is (rg16 unorm), and the pigment still
    /// in the water (rgba16 unorm, premultiplied), each twice over for a step to read one
    /// and write the other. Unorm, not half float: see `makeState`.
    var water: [MTLTexture]
    var pigment: [MTLTexture]
    /// Which of each pair holds the state now.
    var current = 0
    /// Scratch at the region's resolution: what leaves each texel for its neighbours.
    var flux: MTLTexture
    /// Pigment settled on the paper since the water came (rgba32 float, premultiplied).
    var settled: MTLTexture
    /// The dry paint that was there before, at the layer's resolution, the size of `region`.
    private(set) var dry: MTLTexture
    /// Seconds of flow simulated so far, and how many the water can be active for.
    var simulated: TimeInterval = 0
    var activeFor: TimeInterval = 0
    /// The renderer's clock when the flow began, which `simulated` counts from.
    let began: TimeInterval
    /// How the water behaves: the settings of the last brush that laid some.
    var settings = BrushDescriptor.Water()

    init(scale: Int, region: MTLScissorRect, water: [MTLTexture], pigment: [MTLTexture], flux: MTLTexture,
         settled: MTLTexture, dry: MTLTexture, began: TimeInterval) {
        self.scale = scale
        self.region = region
        self.water = water
        self.pigment = pigment
        self.flux = flux
        self.settled = settled
        self.dry = dry
        self.began = began
    }

    var isActive: Bool { simulated < activeFor }
    var texels: MTLSize { MTLSize(width: region.width / scale, height: region.height / scale, depth: 1) }

    fileprivate func replace(region: MTLScissorRect, water: [MTLTexture], pigment: [MTLTexture], flux: MTLTexture,
                             settled: MTLTexture, dry: MTLTexture) {
        self.region = region
        self.water = water
        self.pigment = pigment
        self.flux = flux
        self.settled = settled
        self.dry = dry
        current = 0
    }
}

/// Runs the water on layers that have it: lays strokes into it, steps it, and keeps the
/// layer's pixels showing the look.
public final class WaterRenderer {
    private let context: MetalContext
    private let compositor: CompositorPipeline
    /// Steps a second of flow; a frame runs the steps the clock owes, up to a few.
    static let stepsPerSecond: Double = 120
    static let maxStepsPerFrame = 16
    /// How far beyond a stroke the water may spread, in layer pixels.
    static let margin = 64
    /// Most water a texel holds; a stroke lays `Water.amount` per unit of coverage.
    static let cap: Float = 1.0
    /// How much the paper's height tilts the water's surface, in water units.
    static let paperWeight: Float = 0.08
    /// Free water that wets the paper through at once; less wets it more slowly.
    static let capacity: Float = 0.3
    /// The surface drop per texel at full canvas tilt.
    static let tiltSlope: Float = 0.05

    init(context: MetalContext, compositor: CompositorPipeline) {
        self.context = context
        self.compositor = compositor
    }

    /// Layer pixels per texel for a canvas of this size: full size up to 4096², half beyond.
    static func scale(for canvasSize: CGSize) -> Int {
        canvasSize.width * canvasSize.height > 4096 * 4096 ? 2 : 1
    }

    /// Mirrors `WaterParams` in Shaders.metal.
    private struct Params {
        var size: SIMD2<UInt32>
        var origin: SIMD2<UInt32>
        var scale: Float
        var layerHeight: Float
        var paperScale: Float
        var flow: Float
        var paperWeight: Float
        var tilt: SIMD2<Float>
        var evaporation: Float
        var settling: Float
        var granulation: Float
        var wick: Float
        var capacity: Float
        var lift: Float
        var mobility: Float
    }

    /// Mirrors `WaterInjectParams`.
    private struct InjectParams {
        var size: SIMD2<UInt32>
        var origin: SIMD2<UInt32>
        var scale: Float
        var layerSize: SIMD2<Float>
        var opacity: Float
        var amount: Float
        var cap: Float
        var mixPigments: Int32
    }

    /// Mirrors `WaterGlazeParams`.
    private struct GlazeParams {
        var size: SIMD2<UInt32>
        var origin: SIMD2<UInt32>
        var scale: Float
        var layerSize: SIMD2<Float>
    }

    // MARK: - State

    /// The water on `layer`, grown to cover `region` (plus the margin the water may spread
    /// into), made if the layer has none. Newly covered dry paint is copied aside from the
    /// layer; what was already under water is carried over.
    func water(on layer: Layer, covering region: MTLScissorRect, textureManager: TextureManager,
               now: TimeInterval, commandBuffer: MTLCommandBuffer) -> LayerWater? {
        let scale = Self.scale(for: CGSize(width: layer.texture.width, height: layer.texture.height))
        let wanted = Self.aligned(Self.grown(region, by: Self.margin, within: layer.texture), to: scale)
        if let water = layer.water {
            if Self.contains(water.region, wanted) { return water }
            let union = Self.aligned(Self.union(water.region, wanted), to: scale)
            guard let grown = makeState(scale: scale, region: union, layer: layer, textureManager: textureManager,
                                        began: water.began, commandBuffer: commandBuffer) else { return nil }
            // The old state into its place in the new
            if let blit = commandBuffer.makeBlitCommandEncoder() {
                let dx = water.region.x - union.x, dy = water.region.y - union.y
                blit.copy(from: water.water[water.current], sourceSlice: 0, sourceLevel: 0,
                          sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0), sourceSize: water.texels,
                          to: grown.water[0], destinationSlice: 0, destinationLevel: 0,
                          destinationOrigin: MTLOrigin(x: dx / scale, y: dy / scale, z: 0))
                blit.copy(from: water.pigment[water.current], sourceSlice: 0, sourceLevel: 0,
                          sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0), sourceSize: water.texels,
                          to: grown.pigment[0], destinationSlice: 0, destinationLevel: 0,
                          destinationOrigin: MTLOrigin(x: dx / scale, y: dy / scale, z: 0))
                blit.copy(from: water.settled, sourceSlice: 0, sourceLevel: 0,
                          sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0), sourceSize: water.texels,
                          to: grown.settled, destinationSlice: 0, destinationLevel: 0,
                          destinationOrigin: MTLOrigin(x: dx / scale, y: dy / scale, z: 0))
                blit.copy(from: water.dry, sourceSlice: 0, sourceLevel: 0,
                          sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0),
                          sourceSize: MTLSize(width: water.region.width, height: water.region.height, depth: 1),
                          to: grown.dry, destinationSlice: 0, destinationLevel: 0,
                          destinationOrigin: MTLOrigin(x: dx, y: dy, z: 0))
                blit.endEncoding()
            }
            water.replace(region: union, water: grown.water, pigment: grown.pigment, flux: grown.flux,
                          settled: grown.settled, dry: grown.dry)
            return water
        }
        guard let fresh = makeState(scale: scale, region: wanted, layer: layer, textureManager: textureManager,
                                    began: now, commandBuffer: commandBuffer) else { return nil }
        layer.water = fresh
        return fresh
    }

    private func makeState(scale: Int, region: MTLScissorRect, layer: Layer, textureManager: TextureManager,
                           began: TimeInterval, commandBuffer: MTLCommandBuffer) -> LayerWater? {
        let w = region.width / scale, h = region.height / scale
        guard w > 0, h > 0 else { return nil }
        func texture(_ format: MTLPixelFormat, _ width: Int, _ height: Int, _ label: String) -> MTLTexture? {
            let desc = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: format, width: width, height: height, mipmapped: false)
            desc.usage = [.shaderRead, .shaderWrite, .renderTarget]
            desc.storageMode = .private
            let texture = context.device.makeTexture(descriptor: desc)
            texture?.label = label
            return texture
        }
        // Water and pigment change by a few ten-thousandths a step, 120 steps a second: in
        // half floats those steps round away near 0.5 and a quarter of the pigment is lost
        // by the time a wash is dry. Unorm16 resolves them (1.5e-5 everywhere, and nothing
        // here exceeds 1); the settled pigment, read and written in place, has to be float
        guard let w0 = texture(.rg16Unorm, w, h, "Water"), let w1 = texture(.rg16Unorm, w, h, "Water"),
              let p0 = texture(.rgba16Unorm, w, h, "Water pigment"), let p1 = texture(.rgba16Unorm, w, h, "Water pigment"),
              let flux = texture(.rgba16Float, w, h, "Water flux"), let settled = texture(.rgba32Float, w, h, "Water settled"),
              let dry = texture(.rgba16Float, region.width, region.height, "Water dry paint") else { return nil }
        for t in [w0, w1, p0, p1, flux, settled] { textureManager.clearTexture(t, commandBuffer: commandBuffer) }
        // The dry paint is what the layer shows now
        if let blit = commandBuffer.makeBlitCommandEncoder() {
            blit.copy(from: layer.texture, sourceSlice: 0, sourceLevel: 0,
                      sourceOrigin: MTLOrigin(x: region.x, y: region.y, z: 0),
                      sourceSize: MTLSize(width: region.width, height: region.height, depth: 1),
                      to: dry, destinationSlice: 0, destinationLevel: 0, destinationOrigin: MTLOrigin(x: 0, y: 0, z: 0))
            blit.endEncoding()
        }
        return LayerWater(scale: scale, region: region, water: [w0, w1], pigment: [p0, p1], flux: flux,
                          settled: settled, dry: dry, began: began)
    }

    // MARK: - Strokes

    /// Lay a finished stroke (`stroke`, the layer-sized stroke texture) into the water on
    /// `layer`: its pigment at `opacity` into the suspended pigment, its coverage as water.
    /// The water stays active for as long as that much could take to dry.
    func inject(stroke: MTLTexture, region: MTLScissorRect, brush: BrushDescriptor, settings: BrushDescriptor.Water,
                opacity: Float, on layer: Layer, dryingTime: TimeInterval, textureManager: TextureManager,
                now: TimeInterval, commandBuffer: MTLCommandBuffer) -> MTLScissorRect? {
        guard let water = water(on: layer, covering: region, textureManager: textureManager, now: now,
                                commandBuffer: commandBuffer) else { return nil }
        let from = water.current, to = 1 - water.current
        var params = InjectParams(
            size: SIMD2(UInt32(water.texels.width), UInt32(water.texels.height)),
            origin: SIMD2(UInt32(water.region.x), UInt32(water.region.y)), scale: Float(water.scale),
            layerSize: SIMD2(Float(layer.texture.width), Float(layer.texture.height)),
            opacity: opacity, amount: settings.amount, cap: Self.cap, mixPigments: 1
        )
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = water.water[to]
        pass.colorAttachments[0].loadAction = .dontCare
        pass.colorAttachments[0].storeAction = .store
        pass.colorAttachments[1].texture = water.pigment[to]
        pass.colorAttachments[1].loadAction = .dontCare
        pass.colorAttachments[1].storeAction = .store
        guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: pass) else { return nil }
        encoder.setRenderPipelineState(context.waterInjectPipelineState)
        compositor.bindQuad(encoder)
        encoder.setFragmentTexture(stroke, index: 0)
        encoder.setFragmentTexture(water.water[from], index: 1)
        encoder.setFragmentTexture(water.pigment[from], index: 2)
        encoder.setFragmentSamplerState(context.linearSampler, index: 0)
        encoder.setFragmentBytes(&params, length: MemoryLayout<InjectParams>.stride, index: 0)
        compositor.drawQuad(encoder, regions: nil)
        encoder.endEncoding()
        water.current = to
        water.settings = settings
        // As much water as a texel can hold takes this long to dry off
        water.activeFor = max(water.activeFor, water.simulated + 3 * dryingTime + 1)
        compose(water, into: layer.texture, commandBuffer: commandBuffer)
        return water.region
    }

    // MARK: - Steps

    /// Run `steps` steps of the flow on `layer`'s water, then rewrite the layer's pixels in
    /// the region. Returns the region rewritten.
    @discardableResult
    func step(_ water: LayerWater, steps: Int, on layer: Layer, settings: BrushDescriptor.Water?, tilt: SIMD2<Float>,
              dryingTime: TimeInterval, commandBuffer: MTLCommandBuffer) -> MTLScissorRect {
        guard steps > 0, let paper = context.brushTextures.paperGrain else { return water.region }
        let settings = settings ?? BrushDescriptor.Water()
        var params = Params(
            size: SIMD2(UInt32(water.texels.width), UInt32(water.texels.height)),
            origin: SIMD2(UInt32(water.region.x), UInt32(water.region.y)),
            // The paper's relief at a coarser scale than the grain the stamps see, so the
            // granulation is blotches rather than speckle
            scale: Float(water.scale), layerHeight: Float(layer.texture.height), paperScale: 0.4,
            flow: 0.06 + 0.14 * settings.flow,
            // The paper's relief steers the water into its valleys, where the last of it
            // sits as it dries and the pigment with it: that is granulation
            paperWeight: 0.06 * settings.granulation,
            // The surface falls the way the tilt points, so the water runs that way
            tilt: -tilt * Self.tiltSlope * Float(water.scale),
            // An ordinary wash's water (0.6 of a texel's most) lasts about the drying time
            evaporation: Float(0.6 / (dryingTime * Self.stepsPerSecond)),
            // Pigment settles onto the paper over seconds in deep water (how fast is the
            // paper's business, not the drying time's) and free water lifts some back up, so
            // about half stays workable while the water is deep; the rest settles as the
            // water thins, wherever it has got to
            settling: Float((0.02 + 0.2 * Double(settings.settling)) / Self.stepsPerSecond),
            granulation: settings.granulation,
            wick: 0.05 + 0.3 * settings.flow, capacity: Self.capacity,
            lift: Float(0.08 / Self.stepsPerSecond),
            // How freely the pigment goes with the water: with the brush's flow, so an
            // ordinary wash (flow 0.5) dries keeping most of its middle, with a darker rim,
            // and a runny one carries its pigment out to a bloom. At 0.4 for every wash the
            // middle of a stroke lost a third of its depth as it dried.
            mobility: 0.4 * settings.flow
        )
        let threads = MTLSize(width: 16, height: 16, depth: 1)
        for _ in 0..<steps {
            let from = water.current, to = 1 - water.current
            guard let encoder = commandBuffer.makeComputeCommandEncoder() else { break }
            encoder.setComputePipelineState(context.waterFluxPipelineState)
            encoder.setTexture(water.water[from], index: 0)
            encoder.setTexture(paper, index: 1)
            encoder.setTexture(water.flux, index: 2)
            encoder.setSamplerState(context.grainSampler, index: 0)
            encoder.setBytes(&params, length: MemoryLayout<Params>.stride, index: 0)
            encoder.dispatchThreads(water.texels, threadsPerThreadgroup: threads)
            encoder.setComputePipelineState(context.waterGatherPipelineState)
            encoder.setTexture(water.water[from], index: 0)
            encoder.setTexture(water.pigment[from], index: 1)
            encoder.setTexture(water.flux, index: 2)
            encoder.setTexture(paper, index: 3)
            encoder.setTexture(water.water[to], index: 4)
            encoder.setTexture(water.pigment[to], index: 5)
            encoder.setTexture(water.settled, index: 6)
            encoder.dispatchThreads(water.texels, threadsPerThreadgroup: threads)
            encoder.endEncoding()
            water.current = to
            water.simulated += 1 / Self.stepsPerSecond
        }
        compose(water, into: layer.texture, commandBuffer: commandBuffer)
        return water.region
    }

    /// The layer's pixels in the region: the settled pigment over the dry paint, and the
    /// pigment still in the water over that.
    private func compose(_ water: LayerWater, into layerTexture: MTLTexture, commandBuffer: MTLCommandBuffer) {
        var params = GlazeParams(
            size: SIMD2(UInt32(water.texels.width), UInt32(water.texels.height)),
            origin: SIMD2(UInt32(water.region.x), UInt32(water.region.y)), scale: Float(water.scale),
            layerSize: SIMD2(Float(layerTexture.width), Float(layerTexture.height))
        )
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = layerTexture
        pass.colorAttachments[0].loadAction = .load
        pass.colorAttachments[0].storeAction = .store
        guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: pass) else { return }
        encoder.setRenderPipelineState(context.waterGlazePipelineState)
        compositor.bindQuad(encoder)
        encoder.setFragmentTexture(water.pigment[water.current], index: 0)
        encoder.setFragmentTexture(water.settled, index: 1)
        encoder.setFragmentTexture(water.dry, index: 2)
        encoder.setFragmentSamplerState(context.linearSampler, index: 0)
        encoder.setFragmentBytes(&params, length: MemoryLayout<GlazeParams>.stride, index: 0)
        compositor.drawQuad(encoder, regions: [water.region])
        encoder.endEncoding()
    }

    // MARK: - Rectangles

    private static func grown(_ r: MTLScissorRect, by margin: Int, within texture: MTLTexture) -> MTLScissorRect {
        let x = max(0, r.x - margin), y = max(0, r.y - margin)
        let maxX = min(texture.width, r.x + r.width + margin), maxY = min(texture.height, r.y + r.height + margin)
        return MTLScissorRect(x: x, y: y, width: maxX - x, height: maxY - y)
    }

    private static func aligned(_ r: MTLScissorRect, to scale: Int) -> MTLScissorRect {
        guard scale > 1 else { return r }
        let x = r.x / scale * scale, y = r.y / scale * scale
        let maxX = (r.x + r.width + scale - 1) / scale * scale, maxY = (r.y + r.height + scale - 1) / scale * scale
        return MTLScissorRect(x: x, y: y, width: maxX - x, height: maxY - y)
    }

    private static func union(_ a: MTLScissorRect, _ b: MTLScissorRect) -> MTLScissorRect {
        let x = min(a.x, b.x), y = min(a.y, b.y)
        let maxX = max(a.x + a.width, b.x + b.width), maxY = max(a.y + a.height, b.y + b.height)
        return MTLScissorRect(x: x, y: y, width: maxX - x, height: maxY - y)
    }

    private static func contains(_ outer: MTLScissorRect, _ inner: MTLScissorRect) -> Bool {
        inner.x >= outer.x && inner.y >= outer.y
            && inner.x + inner.width <= outer.x + outer.width && inner.y + inner.height <= outer.y + outer.height
    }
}
