import Metal
import simd

/// Composites layer textures together and renders the final result to the display.
final class CompositorPipeline {
    private let context: MetalContext

    // Full-screen quad vertices: position (float2) + texCoord (float2)
    private let quadVertexBuffer: MTLBuffer

    init(context: MetalContext) {
        self.context = context

        // Full-screen quad (two triangles) in NDC
        let quadVertices: [Float] = [
            // pos.x, pos.y, tex.u, tex.v
            -1, -1, 0, 1,
             1, -1, 1, 1,
             1,  1, 1, 0,
            -1, -1, 0, 1,
             1,  1, 1, 0,
            -1,  1, 0, 0,
        ]

        self.quadVertexBuffer = context.device.makeBuffer(
            bytes: quadVertices,
            length: quadVertices.count * MemoryLayout<Float>.size,
            options: .storageModeShared
        )!
    }

    /// Composite a source texture onto a destination texture with normal blending.
    func compositeNormal(
        source: MTLTexture,
        onto destination: MTLTexture,
        opacity: Float,
        commandBuffer: MTLCommandBuffer
    ) {
        var layerOpacity = opacity
        var identity = float4x4(diagonal: SIMD4<Float>(1, 1, 1, 1))

        let passDesc = MTLRenderPassDescriptor()
        passDesc.colorAttachments[0].texture = destination
        passDesc.colorAttachments[0].loadAction = .load
        passDesc.colorAttachments[0].storeAction = .store

        guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: passDesc) else { return }

        encoder.setRenderPipelineState(context.compositeNormalPipelineState)
        encoder.setVertexBuffer(quadVertexBuffer, offset: 0, index: 0)
        encoder.setVertexBytes(&identity, length: MemoryLayout<float4x4>.size, index: 1)
        encoder.setFragmentTexture(source, index: 0)
        encoder.setFragmentSamplerState(context.linearSampler, index: 0)
        encoder.setFragmentBytes(&layerOpacity, length: MemoryLayout<Float>.size, index: 0)

        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6)
        encoder.endEncoding()
    }

    /// Composite a source texture onto a destination texture using a specific blend mode.
    /// For Normal mode, falls back to the standard alpha-blend pipeline.
    /// For other modes, reads both source and destination into a shader that computes the blend,
    /// then writes the result to a temp texture and blits it back to the destination.
    func compositeWithBlendMode(
        source: MTLTexture,
        onto destination: MTLTexture,
        opacity: Float,
        blendMode: LayerBlendMode,
        tempTexture: MTLTexture,
        commandBuffer: MTLCommandBuffer
    ) {
        if blendMode == .normal {
            compositeNormal(source: source, onto: destination, opacity: opacity, commandBuffer: commandBuffer)
            return
        }

        var layerOpacity = opacity
        var mode: Int32 = {
            switch blendMode {
            case .normal: return 0
            case .multiply: return 1
            case .screen: return 2
            case .overlay: return 3
            case .darken: return 4
            case .lighten: return 5
            }
        }()
        var identity = float4x4(diagonal: SIMD4<Float>(1, 1, 1, 1))

        // Render composited result into temp texture
        let passDesc = MTLRenderPassDescriptor()
        passDesc.colorAttachments[0].texture = tempTexture
        passDesc.colorAttachments[0].loadAction = .clear
        passDesc.colorAttachments[0].storeAction = .store
        passDesc.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)

        guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: passDesc) else { return }
        encoder.setRenderPipelineState(context.compositeBlendPipelineState)
        encoder.setVertexBuffer(quadVertexBuffer, offset: 0, index: 0)
        encoder.setVertexBytes(&identity, length: MemoryLayout<float4x4>.size, index: 1)
        encoder.setFragmentTexture(source, index: 0)
        encoder.setFragmentTexture(destination, index: 1)
        encoder.setFragmentSamplerState(context.linearSampler, index: 0)
        encoder.setFragmentBytes(&layerOpacity, length: MemoryLayout<Float>.size, index: 0)
        encoder.setFragmentBytes(&mode, length: MemoryLayout<Int32>.size, index: 1)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6)
        encoder.endEncoding()

        // Blit the result back to destination
        guard let blit = commandBuffer.makeBlitCommandEncoder() else { return }
        blit.copy(from: tempTexture,
                  sourceSlice: 0, sourceLevel: 0,
                  sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0),
                  sourceSize: MTLSize(width: destination.width, height: destination.height, depth: 1),
                  to: destination,
                  destinationSlice: 0, destinationLevel: 0,
                  destinationOrigin: MTLOrigin(x: 0, y: 0, z: 0))
        blit.endEncoding()
    }

    /// Render a texture to the screen drawable with the display shader (white background).
    func renderToScreen(
        composite: MTLTexture,
        drawable: MTLTexture,
        transform: CanvasTransform,
        viewSize: CGSize,
        backgroundColor: (r: Double, g: Double, b: Double) = (0.18, 0.18, 0.18),
        commandBuffer: MTLCommandBuffer
    ) {
        var transformMatrix = transform.transformMatrix(viewSize: viewSize)

        let passDesc = MTLRenderPassDescriptor()
        passDesc.colorAttachments[0].texture = drawable
        passDesc.colorAttachments[0].loadAction = .clear
        passDesc.colorAttachments[0].storeAction = .store
        passDesc.colorAttachments[0].clearColor = MTLClearColor(red: backgroundColor.r, green: backgroundColor.g, blue: backgroundColor.b, alpha: 1.0)

        guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: passDesc) else { return }

        encoder.setRenderPipelineState(context.displayPipelineState)

        // Generate canvas quad vertices in canvas coordinates
        let canvasW = Float(composite.width)
        let canvasH = Float(composite.height)
        let canvasQuad: [Float] = [
            0, 0,           0, 1,
            canvasW, 0,     1, 1,
            canvasW, canvasH, 1, 0,
            0, 0,           0, 1,
            canvasW, canvasH, 1, 0,
            0, canvasH,     0, 0,
        ]

        let canvasBuffer = context.device.makeBuffer(
            bytes: canvasQuad,
            length: canvasQuad.count * MemoryLayout<Float>.size,
            options: .storageModeShared
        )

        encoder.setVertexBuffer(canvasBuffer, offset: 0, index: 0)
        encoder.setVertexBytes(&transformMatrix, length: MemoryLayout<float4x4>.size, index: 1)
        encoder.setFragmentTexture(composite, index: 0)
        encoder.setFragmentSamplerState(context.linearSampler, index: 0)

        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6)
        encoder.endEncoding()
    }
}
