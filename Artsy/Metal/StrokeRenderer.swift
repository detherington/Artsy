import Metal
import simd

/// Renders stroke geometry into a stroke texture.
final class StrokeRenderer {
    private let context: MetalContext
    private let brushEngine = BrushEngine()

    init(context: MetalContext) {
        self.context = context
    }

    /// Draw `points[range]` into an open render pass on a stroke texture: the ribbon first,
    /// then tip-quad caps using a radial-distance shader for smooth, rounded endpoints
    /// (Procreate-style). One copy is drawn per entry in `mirrors` (symmetry).
    ///
    /// - Returns: the canvas-space bounds of each copy that produced geometry.
    @discardableResult
    func encode(
        points: [InterpolatedPoint],
        range: ClosedRange<Int>,
        brush: BrushDescriptor,
        color: StrokeColor,
        startCap: Bool,
        endCap: Bool,
        mirrors: [(CGPoint) -> CGPoint],
        encoder: MTLRenderCommandEncoder,
        canvasSize: CGSize
    ) -> [CGRect] {
        var transform = orthographicProjection(
            left: 0, right: Float(canvasSize.width),
            bottom: 0, top: Float(canvasSize.height),
            near: -1, far: 1
        )
        var brushColor = color.simd
        var hardness = brush.hardness
        var drawn: [CGRect] = []

        for mirror in mirrors {
            let geometry = brushEngine.generateGeometry(
                for: points, range: range, brush: brush,
                startCap: startCap, endCap: endCap, transform: mirror
            )
            guard !geometry.isEmpty else { continue }
            drawn.append(geometry.bounds)

            if !geometry.ribbonIndices.isEmpty,
               let vb = makeBuffer(geometry.ribbonVertices), let ib = makeIndexBuffer(geometry.ribbonIndices) {
                encoder.setRenderPipelineState(ribbonPipelineState(brush: brush))
                encoder.setVertexBuffer(vb, offset: 0, index: 0)
                encoder.setVertexBytes(&transform, length: MemoryLayout<float4x4>.size, index: 1)
                encoder.setFragmentBytes(&brushColor, length: MemoryLayout<SIMD4<Float>>.size, index: 0)
                encoder.setFragmentBytes(&hardness, length: MemoryLayout<Float>.size, index: 1)
                encoder.drawIndexedPrimitives(
                    type: .triangle, indexCount: geometry.ribbonIndices.count,
                    indexType: .uint32, indexBuffer: ib, indexBufferOffset: 0
                )
            }

            if !geometry.capIndices.isEmpty,
               let capVB = makeBuffer(geometry.capVertices), let capIB = makeIndexBuffer(geometry.capIndices) {
                encoder.setRenderPipelineState(radialCapPipelineState(brush: brush))
                encoder.setVertexBuffer(capVB, offset: 0, index: 0)
                encoder.setVertexBytes(&transform, length: MemoryLayout<float4x4>.size, index: 1)
                encoder.setFragmentBytes(&brushColor, length: MemoryLayout<SIMD4<Float>>.size, index: 0)
                encoder.setFragmentBytes(&hardness, length: MemoryLayout<Float>.size, index: 1)
                encoder.drawIndexedPrimitives(
                    type: .triangle, indexCount: geometry.capIndices.count,
                    indexType: .uint32, indexBuffer: capIB, indexBufferOffset: 0
                )
            }
        }
        return drawn
    }

    /// Mirrors `StampParams` in Shaders.metal.
    private struct StampParams {
        var color: SIMD4<Float>
        var hardness: Float
        var tipIsTexture: Int32
        var grainMode: Int32
        var grainScale: Float
        var grainDepth: Float
    }

    /// Draw dabs into an open render pass on a stroke texture, once per entry in `mirrors`
    /// (symmetry). Dabs blend source-over, in the order given.
    ///
    /// - Parameter opacityScale: multiplies every dab's opacity.
    /// - Returns: the canvas-space bounds of each copy.
    @discardableResult
    func encode(
        dabs: [Dab],
        brush: BrushDescriptor,
        settings: StampSettings,
        color: StrokeColor,
        opacityScale: Float,
        mirrors: [(CGPoint) -> CGPoint],
        encoder: MTLRenderCommandEncoder,
        canvasSize: CGSize
    ) -> [CGRect] {
        guard !dabs.isEmpty, let paper = context.brushTextures.paperGrain else { return [] }

        var transform = orthographicProjection(
            left: 0, right: Float(canvasSize.width),
            bottom: 0, top: Float(canvasSize.height),
            near: -1, far: 1
        )
        let tipTexture = context.brushTextures.tipTexture(for: settings.tip)
        var params = StampParams(
            color: color.simd,
            hardness: brush.hardness,
            tipIsTexture: tipTexture == nil ? 0 : 1,
            grainMode: { switch settings.grain?.mode { case .multiply: return 1; case .height: return 2; case nil: return 0 } }(),
            grainScale: settings.grain?.scale ?? 1,
            grainDepth: settings.grain?.depth ?? 0
        )

        encoder.setRenderPipelineState(context.stampPipelineState)
        encoder.setVertexBytes(&transform, length: MemoryLayout<float4x4>.size, index: 1)
        encoder.setFragmentBytes(&params, length: MemoryLayout<StampParams>.stride, index: 0)
        // Both slots need a texture even when the shader won't sample one of them.
        encoder.setFragmentTexture(tipTexture ?? paper, index: 0)
        encoder.setFragmentTexture(paper, index: 1)
        encoder.setFragmentSamplerState(context.tipSampler, index: 0)
        encoder.setFragmentSamplerState(context.grainSampler, index: 1)

        var drawn: [CGRect] = []
        for mirror in mirrors {
            // Eight floats per dab, matching `StampInstance` in Shaders.metal
            var instances: [Float] = []
            instances.reserveCapacity(dabs.count * 8)
            var bounds = CGRect.null

            for dab in dabs {
                let center = mirror(dab.center)
                // A mirror turns the tip as well as moving it.
                let ahead = mirror(CGPoint(x: dab.center.x + CGFloat(cos(dab.angle)),
                                           y: dab.center.y + CGFloat(sin(dab.angle))))
                let angle = Float(atan2(ahead.y - center.y, ahead.x - center.x))
                instances += [Float(center.x), Float(center.y), dab.size, angle,
                              dab.opacity * opacityScale, dab.seed, dab.reach, dab.aspect]

                // Half the diagonal covers the quad at any rotation
                let reach = CGFloat(dab.size * max(dab.aspect, 1)) * 0.7072
                bounds = bounds.union(CGRect(x: center.x - reach, y: center.y - reach, width: reach * 2, height: reach * 2))
            }

            guard let buffer = makeBuffer(instances) else { continue }
            encoder.setVertexBuffer(buffer, offset: 0, index: 0)
            encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6, instanceCount: dabs.count)
            drawn.append(bounds)
        }
        return drawn
    }

    // MARK: - Pipeline Selection

    private func ribbonShader(of brush: BrushDescriptor) -> RibbonShader {
        if case .ribbon(let shader) = brush.rendering { return shader }
        return .procedural
    }

    private func ribbonPipelineState(brush: BrushDescriptor) -> MTLRenderPipelineState {
        switch ribbonShader(of: brush) {
        case .procedural: return context.strokeProceduralPipelineState
        case .watercolor: return context.strokeWatercolorPipelineState
        case .acrylic: return context.strokeAcrylicPipelineState
        case .oil: return context.strokeOilPipelineState
        }
    }

    private func radialCapPipelineState(brush: BrushDescriptor) -> MTLRenderPipelineState {
        switch ribbonShader(of: brush) {
        case .watercolor: return context.strokeRadialWatercolorPipelineState
        case .acrylic: return context.strokeRadialAcrylicPipelineState
        case .oil: return context.strokeRadialOilPipelineState
        case .procedural: return context.strokeRadialPipelineState
        }
    }

    // MARK: - Buffer Helpers

    private func makeBuffer(_ data: [Float]) -> MTLBuffer? {
        context.device.makeBuffer(
            bytes: data,
            length: data.count * MemoryLayout<Float>.size,
            options: .storageModeShared
        )
    }

    private func makeIndexBuffer(_ data: [UInt32]) -> MTLBuffer? {
        context.device.makeBuffer(
            bytes: data,
            length: data.count * MemoryLayout<UInt32>.size,
            options: .storageModeShared
        )
    }

    // MARK: - Math

    private func orthographicProjection(
        left: Float, right: Float,
        bottom: Float, top: Float,
        near: Float, far: Float
    ) -> float4x4 {
        let sx = 2.0 / (right - left)
        let sy = 2.0 / (top - bottom)
        let sz = 1.0 / (far - near)
        let tx = -(right + left) / (right - left)
        let ty = -(top + bottom) / (top - bottom)
        let tz = -near / (far - near)

        return float4x4(columns: (
            SIMD4<Float>(sx,  0,  0, 0),
            SIMD4<Float>( 0, sy,  0, 0),
            SIMD4<Float>( 0,  0, sz, 0),
            SIMD4<Float>(tx, ty, tz, 1)
        ))
    }
}
