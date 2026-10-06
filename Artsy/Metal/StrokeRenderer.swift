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

    // MARK: - Pipeline Selection

    private func ribbonPipelineState(brush: BrushDescriptor) -> MTLRenderPipelineState {
        switch brush.shaderType {
        case .procedural: return context.strokeProceduralPipelineState
        case .pencil: return context.strokePencilPipelineState
        case .watercolor: return context.strokeWatercolorPipelineState
        case .acrylic: return context.strokeAcrylicPipelineState
        case .oil: return context.strokeOilPipelineState
        }
    }

    private func radialCapPipelineState(brush: BrushDescriptor) -> MTLRenderPipelineState {
        switch brush.shaderType {
        case .pencil: return context.strokeRadialPencilPipelineState
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
