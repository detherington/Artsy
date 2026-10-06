import Metal
import simd

/// Draws smudge dabs straight into a layer. See the smudge section of Shaders.metal.
///
/// Every dab is two small render passes, in strict order: lay down the paint the brush
/// carries, then pick up what is now under the dab. The carried paint lives in a texture
/// mapped to the dab's quad, so moving the dab moves the paint. One carry per symmetry copy;
/// they last for a stroke.
final class SmudgeRenderer {
    private let context: MetalContext
    /// Edge of the square carry textures. A larger dab is carried at lower resolution.
    static let carrySize = 256

    private struct Carry {
        let texture: MTLTexture
        /// Texels in use since the last pickup; nil until something has been picked up.
        var texels: SIMD2<Float>?
    }
    private var carries: [Carry] = []
    /// A copy of the layer under the dab being laid, for the deposit pass to read.
    private var backdrop: MTLTexture?

    init(context: MetalContext) {
        self.context = context
    }

    /// Forget the carried paint. Call at pen-down.
    func beginStroke() {
        for index in carries.indices { carries[index].texels = nil }
    }

    /// Mirrors `SmudgeParams` in Shaders.metal.
    private struct DepositParams {
        var color: SIMD4<Float>
        var hardness: Float
        var tipIsTexture: Int32
        var colorRate: Float
        var carryTexels: SIMD2<Float>
        var backdropOrigin: SIMD2<UInt32>
        var mixPigments: Int32
    }

    /// Mirrors `SmudgePickupParams` in Shaders.metal.
    private struct PickupParams {
        var center: SIMD2<Float>
        var size: Float
        var angle: Float
        var aspect: Float
        var canvasSize: SIMD2<Float>
        var carryTexels: SIMD2<Float>
        var dulling: Int32
        var hardness: Float
        var tipIsTexture: Int32
    }

    /// Lay `dabs` into `layer`, in order, one copy per entry in `mirrors`.
    ///
    /// - Parameter opacityScale: multiplies every dab's opacity.
    /// - Returns: the canvas-space bounds of each copy.
    func encode(
        dabs: [Dab],
        brush: BrushDescriptor,
        settings: StampSettings,
        smudge: StampSettings.Smudge,
        color: StrokeColor,
        opacityScale: Float,
        mirrors: [(CGPoint) -> CGPoint],
        layer: MTLTexture,
        commandBuffer: MTLCommandBuffer,
        canvasSize: CGSize
    ) -> [CGRect] {
        guard !dabs.isEmpty, let paper = context.brushTextures.paperGrain else { return [] }
        while carries.count < mirrors.count {
            guard let texture = makeCarry() else { return [] }
            carries.append(Carry(texture: texture, texels: nil))
        }

        let tipTexture = context.brushTextures.tipTexture(for: settings.tip) ?? paper
        let tipIsTexture: Int32 = settings.tip == .round ? 0 : 1
        var transform = StrokeRenderer.orthographicProjection(
            left: 0, right: Float(canvasSize.width),
            bottom: 0, top: Float(canvasSize.height),
            near: -1, far: 1
        )
        let fraction = smudge.depositFraction(spacing: settings.spacing)
        let carrySize = Float(Self.carrySize)

        var drawn: [CGRect] = []
        for (index, mirror) in mirrors.enumerated() {
            var bounds = CGRect.null
            for dab in dabs {
                let center = mirror(dab.center)
                // A mirror turns the tip as well as moving it.
                let ahead = mirror(CGPoint(x: dab.center.x + CGFloat(cos(dab.angle)),
                                           y: dab.center.y + CGFloat(sin(dab.angle))))
                let angle = Float(atan2(ahead.y - center.y, ahead.x - center.x))
                let reach = CGFloat(dab.size * max(dab.aspect, 1)) * 0.7072
                bounds = bounds.union(CGRect(x: center.x - reach, y: center.y - reach, width: reach * 2, height: reach * 2))

                // 1. Lay down what the brush carries. Nothing to lay on the first dab. The
                // fragment reads the layer from a copy of the patch under the dab, since a
                // render pass cannot read its own target.
                if let texels = carries[index].texels,
                   let patch = layerPatch(around: center, reach: reach, layer: layer, commandBuffer: commandBuffer) {
                    let pass = MTLRenderPassDescriptor()
                    pass.colorAttachments[0].texture = layer
                    pass.colorAttachments[0].loadAction = .load
                    pass.colorAttachments[0].storeAction = .store
                    guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: pass) else { continue }
                    // One `StampInstance`, as `StrokeRenderer.encode(dabs:…)` lays them out
                    var instance: [Float] = [Float(center.x), Float(center.y), dab.size, angle,
                                             dab.opacity * opacityScale * fraction, dab.seed, dab.reach, dab.aspect,
                                             dab.pathDistance, dab.secondAngle]
                    var params = DepositParams(color: color.simd, hardness: brush.hardness, tipIsTexture: tipIsTexture,
                                               colorRate: smudge.colorRate, carryTexels: texels,
                                               backdropOrigin: SIMD2(UInt32(patch.x), UInt32(patch.y)),
                                               mixPigments: brush.mixing == .pigment ? 1 : 0)
                    encoder.setRenderPipelineState(context.smudgeDepositPipelineState)
                    encoder.setVertexBytes(&instance, length: instance.count * MemoryLayout<Float>.size, index: 0)
                    encoder.setVertexBytes(&transform, length: MemoryLayout<float4x4>.size, index: 1)
                    encoder.setFragmentBytes(&params, length: MemoryLayout<DepositParams>.stride, index: 0)
                    encoder.setFragmentTexture(tipTexture, index: 0)
                    encoder.setFragmentTexture(carries[index].texture, index: 1)
                    encoder.setFragmentTexture(backdrop, index: 2)
                    encoder.setFragmentSamplerState(context.tipSampler, index: 0)
                    encoder.setFragmentSamplerState(context.linearSampler, index: 1)
                    encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6, instanceCount: 1)
                    encoder.endEncoding()
                }

                // 2. Pick up what is under the dab now. Smearing keeps the paint's layout, a
                // texel per canvas pixel; dulling keeps one colour, so two texels will do.
                let texels: SIMD2<Float> = smudge.mode == .dulling
                    ? SIMD2(2, 2)
                    : SIMD2(min(carrySize, max(2, (dab.size * max(dab.aspect, 1)).rounded(.up))),
                            min(carrySize, max(2, dab.size.rounded(.up))))
                let pass = MTLRenderPassDescriptor()
                pass.colorAttachments[0].texture = carries[index].texture
                pass.colorAttachments[0].loadAction = .dontCare
                pass.colorAttachments[0].storeAction = .store
                guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: pass) else { continue }
                var params = PickupParams(
                    center: SIMD2(Float(center.x), Float(center.y)), size: dab.size, angle: angle, aspect: dab.aspect,
                    canvasSize: SIMD2(Float(canvasSize.width), Float(canvasSize.height)),
                    carryTexels: texels, dulling: smudge.mode == .dulling ? 1 : 0,
                    hardness: brush.hardness, tipIsTexture: tipIsTexture
                )
                encoder.setViewport(MTLViewport(originX: 0, originY: 0, width: Double(texels.x), height: Double(texels.y),
                                                znear: 0, zfar: 1))
                encoder.setRenderPipelineState(context.smudgePickupPipelineState)
                encoder.setFragmentBytes(&params, length: MemoryLayout<PickupParams>.stride, index: 0)
                encoder.setFragmentTexture(layer, index: 0)
                encoder.setFragmentTexture(tipTexture, index: 1)
                encoder.setFragmentSamplerState(context.linearSampler, index: 0)
                encoder.setFragmentSamplerState(context.tipSampler, index: 1)
                encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6)
                encoder.endEncoding()
                carries[index].texels = texels
            }
            drawn.append(bounds)
        }
        return drawn
    }

    /// Copy the layer's pixels within `reach` of `center` (canvas coordinates) into
    /// `backdrop`, at its origin. Returns the patch in layer pixels, or nil if it is empty
    /// or there is no room for it.
    private func layerPatch(around center: CGPoint, reach: CGFloat, layer: MTLTexture,
                            commandBuffer: MTLCommandBuffer) -> MTLScissorRect? {
        let width = layer.width, height = layer.height
        let minX = max(0, Int((center.x - reach).rounded(.down)) - 1)
        let maxX = min(width, Int((center.x + reach).rounded(.up)) + 1)
        let minY = max(0, height - Int((center.y + reach).rounded(.up)) - 1)
        let maxY = min(height, height - Int((center.y - reach).rounded(.down)) + 1)
        guard maxX > minX, maxY > minY else { return nil }
        let patch = MTLScissorRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)

        if backdrop == nil || backdrop!.width < patch.width || backdrop!.height < patch.height {
            let side = Self.carrySize << (0...8).first { patch.width <= Self.carrySize << $0 && patch.height <= Self.carrySize << $0 }!
            let desc = MTLTextureDescriptor.texture2DDescriptor(
                pixelFormat: layer.pixelFormat, width: min(side, max(width, patch.width)),
                height: min(side, max(height, patch.height)), mipmapped: false
            )
            desc.usage = [.shaderRead]
            desc.storageMode = .private
            backdrop = context.device.makeTexture(descriptor: desc)
            backdrop?.label = "Smudge backdrop"
        }
        guard let backdrop, let blit = commandBuffer.makeBlitCommandEncoder() else { return nil }
        blit.copy(from: layer, sourceSlice: 0, sourceLevel: 0,
                  sourceOrigin: MTLOrigin(x: patch.x, y: patch.y, z: 0),
                  sourceSize: MTLSize(width: patch.width, height: patch.height, depth: 1),
                  to: backdrop, destinationSlice: 0, destinationLevel: 0,
                  destinationOrigin: MTLOrigin(x: 0, y: 0, z: 0))
        blit.endEncoding()
        return patch
    }

    private func makeCarry() -> MTLTexture? {
        let desc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba16Float, width: Self.carrySize, height: Self.carrySize, mipmapped: false
        )
        desc.usage = [.shaderRead, .renderTarget]
        desc.storageMode = .private
        let texture = context.device.makeTexture(descriptor: desc)
        texture?.label = "Smudge carry"
        return texture
    }
}
