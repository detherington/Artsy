import Metal
import simd

/// Renders stroke geometry onto the active stroke texture.
final class StrokeRenderer {
    private let context: MetalContext
    private let brushEngine = BrushEngine()

    init(context: MetalContext) {
        self.context = context
    }

    /// Render interpolated points onto the target texture using the specified brush.
    /// Renders the ribbon first, then overlays tip-quad caps at the start and end
    /// using a radial-distance shader for smooth, rounded endpoints (Procreate-style).
    func render(
        points: [InterpolatedPoint],
        brush: BrushDescriptor,
        color: StrokeColor,
        targetTexture: MTLTexture,
        commandBuffer: MTLCommandBuffer,
        canvasSize: CGSize,
        isEraser: Bool = false
    ) {
        guard !points.isEmpty else { return }

        var transform = orthographicProjection(
            left: 0, right: Float(canvasSize.width),
            bottom: 0, top: Float(canvasSize.height),
            near: -1, far: 1
        )
        var brushColor = color.simd
        var hardness = brush.hardness

        let passDesc = MTLRenderPassDescriptor()
        passDesc.colorAttachments[0].texture = targetTexture
        passDesc.colorAttachments[0].loadAction = .load
        passDesc.colorAttachments[0].storeAction = .store

        guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: passDesc) else { return }

        // 1. Ribbon (for strokes with 2+ points)
        if points.count >= 2 {
            let (stripVerts, stripIndices) = brushEngine.generateStripVertices(for: points, brush: brush)
            if !stripVerts.isEmpty, let vb = makeBuffer(stripVerts), let ib = makeIndexBuffer(stripIndices) {
                let ribbonPipeline = ribbonPipelineState(brush: brush, isEraser: isEraser)
                encoder.setRenderPipelineState(ribbonPipeline)
                encoder.setVertexBuffer(vb, offset: 0, index: 0)
                encoder.setVertexBytes(&transform, length: MemoryLayout<float4x4>.size, index: 1)
                encoder.setFragmentBytes(&brushColor, length: MemoryLayout<SIMD4<Float>>.size, index: 0)
                encoder.setFragmentBytes(&hardness, length: MemoryLayout<Float>.size, index: 1)
                encoder.drawIndexedPrimitives(
                    type: .triangle, indexCount: stripIndices.count,
                    indexType: .uint32, indexBuffer: ib, indexBufferOffset: 0
                )
            }
        }

        // 2. Round caps at start/end (or a single dot if only one point)
        let (capVerts, capIndices) = brushEngine.generateCapVertices(for: points, brush: brush)
        if !capVerts.isEmpty, let capVB = makeBuffer(capVerts), let capIB = makeIndexBuffer(capIndices) {
            let capPipeline = radialCapPipelineState(brush: brush, isEraser: isEraser)
            encoder.setRenderPipelineState(capPipeline)
            encoder.setVertexBuffer(capVB, offset: 0, index: 0)
            encoder.setVertexBytes(&transform, length: MemoryLayout<float4x4>.size, index: 1)
            encoder.setFragmentBytes(&brushColor, length: MemoryLayout<SIMD4<Float>>.size, index: 0)
            encoder.setFragmentBytes(&hardness, length: MemoryLayout<Float>.size, index: 1)
            encoder.drawIndexedPrimitives(
                type: .triangle, indexCount: capIndices.count,
                indexType: .uint32, indexBuffer: capIB, indexBufferOffset: 0
            )
        }

        encoder.endEncoding()
    }

    // MARK: - Pipeline Selection

    private func ribbonPipelineState(brush: BrushDescriptor, isEraser: Bool) -> MTLRenderPipelineState {
        if isEraser { return context.strokeEraserPipelineState }
        switch brush.shaderType {
        case .procedural: return context.strokeProceduralPipelineState
        case .pencil: return context.strokePencilPipelineState
        case .textured: return context.strokeTexturedPipelineState
        case .watercolor: return context.strokeWatercolorPipelineState
        case .acrylic: return context.strokeAcrylicPipelineState
        }
    }

    private func radialCapPipelineState(brush: BrushDescriptor, isEraser: Bool) -> MTLRenderPipelineState {
        if isEraser { return context.strokeRadialEraserPipelineState }
        switch brush.shaderType {
        case .pencil: return context.strokeRadialPencilPipelineState
        case .watercolor: return context.strokeRadialWatercolorPipelineState
        case .acrylic: return context.strokeRadialAcrylicPipelineState
        case .procedural, .textured: return context.strokeRadialPipelineState
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
