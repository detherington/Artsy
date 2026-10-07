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

    /// The in-progress stroke, to be merged into the active layer while compositing it.
    struct StrokeOverlay {
        /// The part of the stroke that will not change again.
        let committed: MTLTexture
        /// The newest part, redrawn every frame.
        let tail: MTLTexture
        /// Caps the whole stroke.
        let opacity: Float
        let erase: Bool
        /// True for dabs, which layer (tail over committed); false for a ribbon, whose two
        /// halves are combined by taking their maximum.
        let accumulates: Bool
        /// How the stroke's colour meets the layer's.
        let mixing: PaintMixing
        /// Set for a stroke that dries as a wash.
        let wet: BrushDescriptor.Wet?
    }

    /// Mirrors `StrokeMergeParams` in Shaders.metal.
    private struct StrokeMergeParams {
        var opacity: Float
        var erase: Int32
        var accumulates: Int32
        var mixing: Int32
        var wetEdges: Float
        var granulation: Float
        var grainScale: Float

        init(_ stroke: StrokeOverlay?) {
            opacity = stroke?.opacity ?? 0
            erase = stroke?.erase == true ? 1 : 0
            accumulates = stroke?.accumulates == true ? 1 : 0
            mixing = stroke?.mixing.shaderValue ?? 0
            wetEdges = stroke?.wet?.edges ?? 0
            granulation = stroke?.wet?.granulation ?? 0
            grainScale = stroke?.wet?.grainScale ?? 1
        }
    }

    /// Draw the full-canvas quad once, or once per scissor rect when `regions` is given.
    private func drawQuad(_ encoder: MTLRenderCommandEncoder, regions: [MTLScissorRect]?) {
        guard let regions else {
            encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6)
            return
        }
        for region in regions {
            encoder.setScissorRect(region)
            encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6)
        }
    }

    /// Composite a source texture onto a destination texture with normal blending.
    /// - Parameter regions: limit the work to these rectangles (texture pixels, origin top-left).
    func compositeNormal(
        source: MTLTexture,
        onto destination: MTLTexture,
        opacity: Float,
        regions: [MTLScissorRect]? = nil,
        commandBuffer: MTLCommandBuffer
    ) {
        compositeLayer(source: source, onto: destination, opacity: opacity, blendMode: .normal,
                       stroke: nil, tempTexture: nil, regions: regions, commandBuffer: commandBuffer)
    }

    /// Composite one layer onto `destination` with its opacity and blend mode.
    ///
    /// Normal mode uses the alpha-blend pipeline. Other modes read both source and
    /// destination in a shader that computes the blend, write the result to `tempTexture`,
    /// and copy it back. Pass `stroke` for the active layer while the pen is down: the stroke
    /// is merged into the layer's colour before opacity and blending, as it will be at pen-up.
    func compositeLayer(
        source: MTLTexture,
        onto destination: MTLTexture,
        opacity: Float,
        blendMode: LayerBlendMode,
        stroke: StrokeOverlay?,
        tempTexture: MTLTexture?,
        regions: [MTLScissorRect]? = nil,
        commandBuffer: MTLCommandBuffer
    ) {
        if let regions, regions.isEmpty { return }

        var layerOpacity = opacity
        var identity = float4x4(diagonal: SIMD4<Float>(1, 1, 1, 1))
        var strokeParams = StrokeMergeParams(stroke)

        func bindCommon(_ encoder: MTLRenderCommandEncoder) {
            encoder.setVertexBuffer(quadVertexBuffer, offset: 0, index: 0)
            encoder.setVertexBytes(&identity, length: MemoryLayout<float4x4>.size, index: 1)
            encoder.setFragmentTexture(source, index: 0)
            encoder.setFragmentSamplerState(context.linearSampler, index: 0)
            encoder.setFragmentBytes(&layerOpacity, length: MemoryLayout<Float>.size, index: 0)
            if let stroke {
                encoder.setFragmentTexture(stroke.committed, index: 2)
                encoder.setFragmentTexture(stroke.tail, index: 3)
                bindPaper(encoder)
                encoder.setFragmentBytes(&strokeParams, length: MemoryLayout<StrokeMergeParams>.size, index: 2)
            }
        }

        guard blendMode != .normal, let tempTexture else {
            let passDesc = MTLRenderPassDescriptor()
            passDesc.colorAttachments[0].texture = destination
            passDesc.colorAttachments[0].loadAction = .load
            passDesc.colorAttachments[0].storeAction = .store

            guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: passDesc) else { return }
            encoder.setRenderPipelineState(stroke == nil ? context.compositeNormalPipelineState
                                                         : context.compositeNormalWithStrokePipelineState)
            bindCommon(encoder)
            drawQuad(encoder, regions: regions)
            encoder.endEncoding()
            return
        }

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

        // Render the blended result into the temp texture. Every pixel that gets copied back
        // is written here first, so there is nothing to load or clear.
        let passDesc = MTLRenderPassDescriptor()
        passDesc.colorAttachments[0].texture = tempTexture
        passDesc.colorAttachments[0].loadAction = .dontCare
        passDesc.colorAttachments[0].storeAction = .store

        guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: passDesc) else { return }
        encoder.setRenderPipelineState(stroke == nil ? context.compositeBlendPipelineState
                                                     : context.compositeBlendWithStrokePipelineState)
        bindCommon(encoder)
        encoder.setFragmentTexture(destination, index: 1)
        encoder.setFragmentBytes(&mode, length: MemoryLayout<Int32>.size, index: 1)
        drawQuad(encoder, regions: regions)
        encoder.endEncoding()

        copyBack(from: tempTexture, to: destination, regions: regions, commandBuffer: commandBuffer)
    }

    /// Paper, for strokes that dry as a wash.
    private func bindPaper(_ encoder: MTLRenderCommandEncoder) {
        if let paper = context.brushTextures.paperGrain {
            encoder.setFragmentTexture(paper, index: 4)
        }
        encoder.setFragmentSamplerState(context.grainSampler, index: 1)
    }

    /// Merge a finished stroke (its `committed` texture; the tail is empty by then) into
    /// `destination` the way the live composite showed it, for strokes fixed-function
    /// blending cannot merge: pigment or glaze mixing, a wash. Reads the layer, so it
    /// renders into `tempTexture` and copies back.
    func mergeStroke(
        _ stroke: StrokeOverlay,
        onto destination: MTLTexture,
        tempTexture: MTLTexture,
        regions: [MTLScissorRect]? = nil,
        commandBuffer: MTLCommandBuffer
    ) {
        if let regions, regions.isEmpty { return }
        var params = StrokeMergeParams(stroke)
        var identity = float4x4(diagonal: SIMD4<Float>(1, 1, 1, 1))

        let passDesc = MTLRenderPassDescriptor()
        passDesc.colorAttachments[0].texture = tempTexture
        passDesc.colorAttachments[0].loadAction = .dontCare
        passDesc.colorAttachments[0].storeAction = .store
        guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: passDesc) else { return }
        encoder.setRenderPipelineState(context.compositeStrokeMergePipelineState)
        encoder.setVertexBuffer(quadVertexBuffer, offset: 0, index: 0)
        encoder.setVertexBytes(&identity, length: MemoryLayout<float4x4>.size, index: 1)
        encoder.setFragmentTexture(stroke.committed, index: 0)
        encoder.setFragmentTexture(destination, index: 1)
        encoder.setFragmentSamplerState(context.linearSampler, index: 0)
        bindPaper(encoder)
        encoder.setFragmentBytes(&params, length: MemoryLayout<StrokeMergeParams>.size, index: 2)
        drawQuad(encoder, regions: regions)
        encoder.endEncoding()

        copyBack(from: tempTexture, to: destination, regions: regions, commandBuffer: commandBuffer)
    }

    private func copyBack(from tempTexture: MTLTexture, to destination: MTLTexture, regions: [MTLScissorRect]?,
                          commandBuffer: MTLCommandBuffer) {
        guard let blit = commandBuffer.makeBlitCommandEncoder() else { return }
        let whole = MTLScissorRect(x: 0, y: 0, width: destination.width, height: destination.height)
        for region in regions ?? [whole] {
            blit.copy(from: tempTexture,
                      sourceSlice: 0, sourceLevel: 0,
                      sourceOrigin: MTLOrigin(x: region.x, y: region.y, z: 0),
                      sourceSize: MTLSize(width: region.width, height: region.height, depth: 1),
                      to: destination,
                      destinationSlice: 0, destinationLevel: 0,
                      destinationOrigin: MTLOrigin(x: region.x, y: region.y, z: 0))
        }
        blit.endEncoding()
    }

    /// Add a layer's height map into `destination`, at the layer's opacity.
    func accumulateHeight(
        source: MTLTexture,
        onto destination: MTLTexture,
        opacity: Float,
        regions: [MTLScissorRect]? = nil,
        commandBuffer: MTLCommandBuffer
    ) {
        if let regions, regions.isEmpty { return }
        var layerOpacity = opacity
        var identity = float4x4(diagonal: SIMD4<Float>(1, 1, 1, 1))

        let passDesc = MTLRenderPassDescriptor()
        passDesc.colorAttachments[0].texture = destination
        passDesc.colorAttachments[0].loadAction = .load
        passDesc.colorAttachments[0].storeAction = .store

        guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: passDesc) else { return }
        encoder.setRenderPipelineState(context.heightAccumulatePipelineState)
        encoder.setVertexBuffer(quadVertexBuffer, offset: 0, index: 0)
        encoder.setVertexBytes(&identity, length: MemoryLayout<float4x4>.size, index: 1)
        encoder.setFragmentTexture(source, index: 0)
        encoder.setFragmentSamplerState(context.linearSampler, index: 0)
        encoder.setFragmentBytes(&layerOpacity, length: MemoryLayout<Float>.size, index: 0)
        drawQuad(encoder, regions: regions)
        encoder.endEncoding()
    }

    /// Remove `source`'s coverage (times `opacity`) from `destination`: how an eraser stroke
    /// is applied to its layer (and, with a height map as the destination, its thickness).
    func erase(
        source: MTLTexture,
        from destination: MTLTexture,
        opacity: Float,
        regions: [MTLScissorRect]? = nil,
        commandBuffer: MTLCommandBuffer
    ) {
        if let regions, regions.isEmpty { return }
        var layerOpacity = opacity
        var identity = float4x4(diagonal: SIMD4<Float>(1, 1, 1, 1))

        let passDesc = MTLRenderPassDescriptor()
        passDesc.colorAttachments[0].texture = destination
        passDesc.colorAttachments[0].loadAction = .load
        passDesc.colorAttachments[0].storeAction = .store

        guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: passDesc) else { return }
        encoder.setRenderPipelineState(destination.pixelFormat == .r16Float ? context.heightErasePipelineState
                                                                           : context.compositeErasePipelineState)
        encoder.setVertexBuffer(quadVertexBuffer, offset: 0, index: 0)
        encoder.setVertexBytes(&identity, length: MemoryLayout<float4x4>.size, index: 1)
        encoder.setFragmentTexture(source, index: 0)
        encoder.setFragmentSamplerState(context.linearSampler, index: 0)
        encoder.setFragmentBytes(&layerOpacity, length: MemoryLayout<Float>.size, index: 0)
        drawQuad(encoder, regions: regions)
        encoder.endEncoding()
    }

    /// Fill `destination` with `source` shrunk to fit it. Meant for a destination a quarter
    /// the size of the source; chain calls for more.
    func downsample(_ source: MTLTexture, into destination: MTLTexture, commandBuffer: MTLCommandBuffer) {
        var identity = float4x4(diagonal: SIMD4<Float>(1, 1, 1, 1))
        let passDesc = MTLRenderPassDescriptor()
        passDesc.colorAttachments[0].texture = destination
        passDesc.colorAttachments[0].loadAction = .dontCare
        passDesc.colorAttachments[0].storeAction = .store

        guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: passDesc) else { return }
        encoder.setRenderPipelineState(context.downsamplePipelineState)
        encoder.setVertexBuffer(quadVertexBuffer, offset: 0, index: 0)
        encoder.setVertexBytes(&identity, length: MemoryLayout<float4x4>.size, index: 1)
        encoder.setFragmentTexture(source, index: 0)
        encoder.setFragmentSamplerState(context.linearSampler, index: 0)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6)
        encoder.endEncoding()
    }

    /// Bring a texture's smaller mip levels up to date from its level 0 where `regions`
    /// (level-0 pixels; nil for all of it) changed. `levels` are views of its levels in
    /// order, level 0 first. Each level is a 2×2 box of the one above, so a region costs a
    /// third of its area over all the levels; the display pass reads the levels when the
    /// canvas is shown smaller than 1:1.
    func refreshLevels(_ levels: [MTLTexture], regions: [MTLScissorRect]?, commandBuffer: MTLCommandBuffer) {
        guard levels.count > 1, regions?.isEmpty != true,
              let encoder = commandBuffer.makeComputeCommandEncoder() else { return }
        encoder.setComputePipelineState(context.mipPipelineState)
        let threadgroup = MTLSize(width: 16, height: 16, depth: 1)
        for level in 1..<levels.count {
            let target = levels[level]
            encoder.setTexture(levels[level - 1], index: 0)
            encoder.setTexture(target, index: 1)
            let whole = MTLScissorRect(x: 0, y: 0, width: target.width, height: target.height)
            for region in regions?.map({ Self.scaled($0, toLevel: level, of: target) }) ?? [whole]
            where region.width > 0 && region.height > 0 {
                var origin = SIMD2<UInt32>(UInt32(region.x), UInt32(region.y))
                encoder.setBytes(&origin, length: MemoryLayout<SIMD2<UInt32>>.size, index: 0)
                encoder.dispatchThreads(MTLSize(width: region.width, height: region.height, depth: 1),
                                        threadsPerThreadgroup: threadgroup)
            }
        }
        encoder.endEncoding()
    }

    /// A level-0 rectangle at `level`, grown to whole texels there.
    static func scaled(_ region: MTLScissorRect, toLevel level: Int, of texture: MTLTexture) -> MTLScissorRect {
        let minX = min(texture.width, region.x >> level), minY = min(texture.height, region.y >> level)
        let maxX = min(texture.width, (region.x + region.width + (1 << level) - 1) >> level)
        let maxY = min(texture.height, (region.y + region.height + (1 << level) - 1) >> level)
        return MTLScissorRect(x: minX, y: minY, width: max(0, maxX - minX), height: max(0, maxY - minY))
    }

    /// Clear rectangles of a texture to transparent.
    func clear(_ texture: MTLTexture, regions: [MTLScissorRect], commandBuffer: MTLCommandBuffer) {
        guard !regions.isEmpty else { return }
        let passDesc = MTLRenderPassDescriptor()
        passDesc.colorAttachments[0].texture = texture
        passDesc.colorAttachments[0].loadAction = .load
        passDesc.colorAttachments[0].storeAction = .store

        guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: passDesc) else { return }
        encodeClear(regions: regions, in: encoder, of: texture)
        encoder.endEncoding()
    }

    /// Clear rectangles inside a render pass that is already open on `texture`, leaving the
    /// scissor reset to the whole texture for whatever is drawn next.
    func encodeClear(regions: [MTLScissorRect], in encoder: MTLRenderCommandEncoder, of texture: MTLTexture) {
        guard !regions.isEmpty else { return }
        var identity = float4x4(diagonal: SIMD4<Float>(1, 1, 1, 1))
        encoder.setRenderPipelineState(texture.pixelFormat == .r16Float ? context.clearHeightPipelineState : context.clearPipelineState)
        encoder.setVertexBuffer(quadVertexBuffer, offset: 0, index: 0)
        encoder.setVertexBytes(&identity, length: MemoryLayout<float4x4>.size, index: 1)
        drawQuad(encoder, regions: regions)
        encoder.setScissorRect(MTLScissorRect(x: 0, y: 0, width: texture.width, height: texture.height))
    }

    /// Composite a source texture onto destination, warped by an affine transform
    /// applied to `sourceRect` (in canvas coords). The source texture is assumed
    /// canvas-sized; `sourceRect` tells us which portion holds the content we
    /// want to render (e.g. a selection's bounding box). Used by the Transform
    /// tool to preview rotations / scales / translations.
    func compositeWithAffineTransform(
        source: MTLTexture,
        sourceRect: CGRect,
        onto destination: MTLTexture,
        canvasSize: CGSize,
        transform: CGAffineTransform,
        opacity: Float,
        commandBuffer: MTLCommandBuffer
    ) {
        let W = Float(canvasSize.width)
        let H = Float(canvasSize.height)

        // Transform each corner of `sourceRect` (canvas-space, Y-up) to its
        // destination position.
        func pt(_ x: CGFloat, _ y: CGFloat) -> (Float, Float) {
            let p = CGPoint(x: x, y: y).applying(transform)
            return (Float(p.x), Float(p.y))
        }
        let (x00, y00) = pt(sourceRect.minX, sourceRect.minY)  // bottom-left (Y-up)
        let (x10, y10) = pt(sourceRect.maxX, sourceRect.minY)  // bottom-right
        let (x11, y11) = pt(sourceRect.maxX, sourceRect.maxY)  // top-right
        let (x01, y01) = pt(sourceRect.minX, sourceRect.maxY)  // top-left

        // UV coordinates into the canvas-sized source texture. Texture Y is
        // Y-down (row 0 = top); canvas Y is Y-up — hence (1 - y/H).
        let u0 = Float(sourceRect.minX) / W
        let u1 = Float(sourceRect.maxX) / W
        let v0 = 1.0 - Float(sourceRect.minY) / H   // canvas bottom → UV v = 1
        let v1 = 1.0 - Float(sourceRect.maxY) / H   // canvas top → UV v = 0

        let quad: [Float] = [
            x00, y00, u0, v0,
            x10, y10, u1, v0,
            x11, y11, u1, v1,
            x00, y00, u0, v0,
            x11, y11, u1, v1,
            x01, y01, u0, v1,
        ]
        guard let vbuf = context.device.makeBuffer(
            bytes: quad,
            length: quad.count * MemoryLayout<Float>.size,
            options: .storageModeShared
        ) else { return }

        // Orthographic projection: canvas space [0..W, 0..H] → NDC [-1..1].
        // Column-major float4x4.
        var projection = float4x4(
            SIMD4<Float>( 2.0 / W, 0, 0, 0),
            SIMD4<Float>( 0, 2.0 / H, 0, 0),
            SIMD4<Float>( 0, 0, 1, 0),
            SIMD4<Float>(-1, -1, 0, 1)
        )
        var layerOpacity = opacity

        let passDesc = MTLRenderPassDescriptor()
        passDesc.colorAttachments[0].texture = destination
        passDesc.colorAttachments[0].loadAction = .load
        passDesc.colorAttachments[0].storeAction = .store

        guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: passDesc) else { return }
        encoder.setRenderPipelineState(destination.pixelFormat == .r16Float ? context.heightAffinePipelineState
                                                                           : context.compositeNormalPipelineState)
        encoder.setVertexBuffer(vbuf, offset: 0, index: 0)
        encoder.setVertexBytes(&projection, length: MemoryLayout<float4x4>.size, index: 1)
        encoder.setFragmentTexture(source, index: 0)
        encoder.setFragmentSamplerState(context.linearSampler, index: 0)
        encoder.setFragmentBytes(&layerOpacity, length: MemoryLayout<Float>.size, index: 0)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6)
        encoder.endEncoding()
    }

    /// Render a texture to the screen drawable with the display shader (white background).
    /// - Parameters:
    ///   - height: the composite's height map, lit as paint relief; nil for none.
    ///   - relief: how strongly the relief is lit; 0 shows the paint flat.
    func renderToScreen(
        composite: MTLTexture,
        height: MTLTexture? = nil,
        relief: Float = 0,
        drawable: MTLTexture,
        transform: CanvasTransform,
        viewSize: CGSize,
        backgroundColor: (r: Double, g: Double, b: Double) = (0.18, 0.18, 0.18),
        commandBuffer: MTLCommandBuffer
    ) {
        var transformMatrix = transform.transformMatrix(viewSize: viewSize)
        var reliefStrength = height == nil ? 0 : relief

        let passDesc = MTLRenderPassDescriptor()
        passDesc.colorAttachments[0].texture = drawable
        passDesc.colorAttachments[0].loadAction = .clear
        passDesc.colorAttachments[0].storeAction = .store
        passDesc.colorAttachments[0].clearColor = MTLClearColor(red: backgroundColor.r, green: backgroundColor.g, blue: backgroundColor.b, alpha: 1.0)

        guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: passDesc) else { return }

        encoder.setRenderPipelineState(drawable.pixelFormat == .rgba16Float ? context.display16PipelineState
                                                                          : context.displayPipelineState)

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

        encoder.setVertexBytes(canvasQuad, length: canvasQuad.count * MemoryLayout<Float>.size, index: 0)
        encoder.setVertexBytes(&transformMatrix, length: MemoryLayout<float4x4>.size, index: 1)
        encoder.setFragmentTexture(composite, index: 0)
        // The slot needs a texture even when the shader will not light anything
        encoder.setFragmentTexture(height ?? composite, index: 1)
        encoder.setFragmentSamplerState(context.displaySampler, index: 0)
        encoder.setFragmentBytes(&reliefStrength, length: MemoryLayout<Float>.size, index: 0)

        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6)
        encoder.endEncoding()
    }
}
