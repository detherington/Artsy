import Metal
import MetalKit

final class CanvasRenderer: NSObject, MTKViewDelegate {
    let context: MetalContext
    let textureManager: TextureManager
    let strokeRenderer: StrokeRenderer
    let compositor: CompositorPipeline

    // Canvas textures
    var activeStrokeTexture: MTLTexture!
    var compositeTexture: MTLTexture!
    var blendTempTexture: MTLTexture!

    let canvasSize: CGSize
    weak var viewModel: CanvasViewModel?

    private var lastRenderedPointCount = 0
    private var hasInitializedTransform = false

    init(context: MetalContext, canvasSize: CGSize) throws {
        self.context = context
        self.canvasSize = canvasSize
        self.textureManager = TextureManager(device: context.device)
        self.strokeRenderer = StrokeRenderer(context: context)
        self.compositor = CompositorPipeline(context: context)

        super.init()

        let w = Int(canvasSize.width)
        let h = Int(canvasSize.height)

        activeStrokeTexture = try textureManager.makeCanvasTexture(width: w, height: h, label: "Active Stroke")
        compositeTexture = try textureManager.makeCanvasTexture(width: w, height: h, label: "Composite")
        blendTempTexture = try textureManager.makeCanvasTexture(width: w, height: h, label: "Blend Temp")

        guard let commandBuffer = context.commandQueue.makeCommandBuffer() else { return }
        textureManager.clearTexture(activeStrokeTexture, commandBuffer: commandBuffer)
        textureManager.clearTexture(compositeTexture, commandBuffer: commandBuffer)
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()
    }

    /// Set up the layer stack on the view model.
    func setupLayerStack(for viewModel: CanvasViewModel) throws {
        let layerStack = LayerStack(
            textureManager: textureManager,
            canvasWidth: Int(canvasSize.width),
            canvasHeight: Int(canvasSize.height)
        )
        guard let commandBuffer = context.commandQueue.makeCommandBuffer() else { return }
        try layerStack.createInitialLayer(commandBuffer: commandBuffer)
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()
        viewModel.layerStack = layerStack

        // Generate initial thumbnails
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            self?.updateAllThumbnails(in: layerStack)
        }
    }

    // MARK: - MTKViewDelegate

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

    func draw(in view: MTKView) {
        guard let viewModel = viewModel,
              let layerStack = viewModel.layerStack,
              let drawable = view.currentDrawable,
              let commandBuffer = context.commandQueue.makeCommandBuffer() else {
            return
        }

        if !hasInitializedTransform && view.bounds.size.width > 0 {
            viewModel.transform.zoomToFit(canvasSize: canvasSize, viewSize: view.bounds.size)
            hasInitializedTransform = true
        }

        // 1. Render active stroke if drawing
        let isErasing = viewModel.currentBrush.category == .utility
        if viewModel.isDrawing {
            let points = viewModel.currentInterpolatedPoints()
            if points.count != lastRenderedPointCount {
                if isErasing {
                    // Eraser renders directly onto the layer texture (destination-out blending)
                    if let activeLayer = layerStack.activeLayer {
                        // Only render the NEW points for eraser (incremental)
                        let newPoints = lastRenderedPointCount > 0 && lastRenderedPointCount < points.count
                            ? Array(points[max(0, lastRenderedPointCount - 1)...])
                            : points
                        strokeRenderer.render(
                            points: newPoints,
                            brush: viewModel.currentBrush,
                            color: StrokeColor.white,
                            targetTexture: activeLayer.texture,
                            commandBuffer: commandBuffer,
                            canvasSize: canvasSize,
                            isEraser: true
                        )
                    }
                } else {
                    // Normal brush renders to active stroke texture
                    textureManager.clearTexture(activeStrokeTexture, commandBuffer: commandBuffer)
                    strokeRenderer.render(
                        points: points,
                        brush: viewModel.currentBrush,
                        color: viewModel.currentColor,
                        targetTexture: activeStrokeTexture,
                        commandBuffer: commandBuffer,
                        canvasSize: canvasSize
                    )
                }
                lastRenderedPointCount = points.count
            }
        }

        // 2. Composite all layers
        textureManager.clearTexture(compositeTexture, commandBuffer: commandBuffer)

        for (i, layer) in layerStack.layers.enumerated() {
            guard layer.isVisible else { continue }

            // Bottom layer always uses normal blending (no destination to blend with)
            // Upper layers use their configured blend mode
            if i == 0 {
                compositor.compositeNormal(
                    source: layer.texture,
                    onto: compositeTexture,
                    opacity: layer.opacity,
                    commandBuffer: commandBuffer
                )
            } else {
                compositor.compositeWithBlendMode(
                    source: layer.texture,
                    onto: compositeTexture,
                    opacity: layer.opacity,
                    blendMode: layer.blendMode,
                    tempTexture: blendTempTexture,
                    commandBuffer: commandBuffer
                )
            }

            if i == layerStack.activeLayerIndex {
                // Composite active stroke if drawing
                if viewModel.isDrawing && !isErasing {
                    compositor.compositeNormal(
                        source: activeStrokeTexture,
                        onto: compositeTexture,
                        opacity: 1.0,
                        commandBuffer: commandBuffer
                    )
                }

                // Composite floating selection content if being moved
                if let floating = viewModel.floatingTexture {
                    // Render floating content shifted by offset
                    let dx = Int(viewModel.floatingOffset.x)
                    let dy = Int(-viewModel.floatingOffset.y)

                    if dx == 0 && dy == 0 {
                        compositor.compositeNormal(
                            source: floating,
                            onto: compositeTexture,
                            opacity: 1.0,
                            commandBuffer: commandBuffer
                        )
                    } else {
                        // Create shifted version for display
                        if let shifted = try? textureManager.makeCanvasTexture(
                            width: floating.width, height: floating.height, label: "FloatDisplay"
                        ) {
                            textureManager.clearTexture(shifted, commandBuffer: commandBuffer)

                            let srcX = max(0, -dx)
                            let srcY = max(0, -dy)
                            let dstX = max(0, dx)
                            let dstY = max(0, dy)
                            let copyW = floating.width - abs(dx)
                            let copyH = floating.height - abs(dy)

                            if copyW > 0, copyH > 0,
                               let blit = commandBuffer.makeBlitCommandEncoder() {
                                blit.copy(from: floating,
                                          sourceSlice: 0, sourceLevel: 0,
                                          sourceOrigin: MTLOrigin(x: srcX, y: srcY, z: 0),
                                          sourceSize: MTLSize(width: copyW, height: copyH, depth: 1),
                                          to: shifted,
                                          destinationSlice: 0, destinationLevel: 0,
                                          destinationOrigin: MTLOrigin(x: dstX, y: dstY, z: 0))
                                blit.endEncoding()
                            }

                            compositor.compositeNormal(
                                source: shifted,
                                onto: compositeTexture,
                                opacity: 1.0,
                                commandBuffer: commandBuffer
                            )
                        }
                    }
                }
            }
        }

        // 3. Display
        compositor.renderToScreen(
            composite: compositeTexture,
            drawable: drawable.texture,
            transform: viewModel.transform,
            viewSize: view.bounds.size,
            backgroundColor: viewModel.canvasBackgroundColor,
            commandBuffer: commandBuffer
        )

        commandBuffer.present(drawable)
        commandBuffer.commit()
    }

    // MARK: - Move / Shift Content

    func shiftLayerContent(layer: Layer, dx: Int, dy: Int, context: MetalContext) {
        let w = layer.texture.width
        let h = layer.texture.height

        // Create a temp copy
        guard let temp = try? textureManager.makeCanvasTexture(width: w, height: h, label: "MoveTemp"),
              let cb = context.commandQueue.makeCommandBuffer(),
              let blit = cb.makeBlitCommandEncoder() else { return }

        // Copy current layer to temp
        blit.copy(from: layer.texture,
                  sourceSlice: 0, sourceLevel: 0,
                  sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0),
                  sourceSize: MTLSize(width: w, height: h, depth: 1),
                  to: temp,
                  destinationSlice: 0, destinationLevel: 0,
                  destinationOrigin: MTLOrigin(x: 0, y: 0, z: 0))
        blit.endEncoding()
        cb.commit()
        cb.waitUntilCompleted()

        // Clear layer
        guard let cb2 = context.commandQueue.makeCommandBuffer() else { return }
        textureManager.clearTexture(layer.texture, commandBuffer: cb2)
        cb2.commit()
        cb2.waitUntilCompleted()

        // Blit shifted — clip to valid regions
        let srcX = max(0, -dx)
        let srcY = max(0, -dy)
        let dstX = max(0, dx)
        let dstY = max(0, dy)
        let copyW = w - abs(dx)
        let copyH = h - abs(dy)

        guard copyW > 0, copyH > 0 else { return }

        guard let cb3 = context.commandQueue.makeCommandBuffer(),
              let blit3 = cb3.makeBlitCommandEncoder() else { return }

        blit3.copy(from: temp,
                   sourceSlice: 0, sourceLevel: 0,
                   sourceOrigin: MTLOrigin(x: srcX, y: srcY, z: 0),
                   sourceSize: MTLSize(width: copyW, height: copyH, depth: 1),
                   to: layer.texture,
                   destinationSlice: 0, destinationLevel: 0,
                   destinationOrigin: MTLOrigin(x: dstX, y: dstY, z: 0))
        blit3.endEncoding()
        cb3.commit()
        cb3.waitUntilCompleted()
    }

    // MARK: - Thumbnails

    /// Generate a thumbnail NSImage from a layer's texture. Max size 64px.
    func generateThumbnail(for layer: Layer, maxSize: Int = 64) -> NSImage? {
        let srcW = layer.texture.width
        let srcH = layer.texture.height
        let aspect = CGFloat(srcW) / CGFloat(srcH)

        let thumbW: Int
        let thumbH: Int
        if aspect >= 1 {
            thumbW = maxSize
            thumbH = Int(CGFloat(maxSize) / aspect)
        } else {
            thumbH = maxSize
            thumbW = Int(CGFloat(maxSize) * aspect)
        }

        // Copy layer texture to a shared texture for CPU readback
        guard let readable = try? textureManager.makeSharedTexture(width: srcW, height: srcH, label: "ThumbRead"),
              let cb = context.commandQueue.makeCommandBuffer(),
              let blit = cb.makeBlitCommandEncoder() else { return nil }
        blit.copy(from: layer.texture, to: readable)
        blit.endEncoding()
        cb.commit()
        cb.waitUntilCompleted()

        // Read float16 pixels
        let bytesPerPixel = 8
        let bytesPerRow = srcW * bytesPerPixel
        var pixelData = [UInt8](repeating: 0, count: srcH * bytesPerRow)
        readable.getBytes(&pixelData, bytesPerRow: bytesPerRow,
            from: MTLRegion(origin: .init(x: 0, y: 0, z: 0), size: .init(width: srcW, height: srcH, depth: 1)),
            mipmapLevel: 0)

        // Convert float16 RGBA to UInt8 RGBA (premultiplied)
        let pixelCount = srcW * srcH
        var rgba = [UInt8](repeating: 0, count: pixelCount * 4)
        pixelData.withUnsafeBytes { raw in
            let f16 = raw.bindMemory(to: UInt16.self)
            for i in 0..<pixelCount {
                let r = Self.float16ToFloat(f16[i*4+0])
                let g = Self.float16ToFloat(f16[i*4+1])
                let b = Self.float16ToFloat(f16[i*4+2])
                let a = Self.float16ToFloat(f16[i*4+3])
                rgba[i*4+0] = UInt8(max(0, min(255, r * 255)))
                rgba[i*4+1] = UInt8(max(0, min(255, g * 255)))
                rgba[i*4+2] = UInt8(max(0, min(255, b * 255)))
                rgba[i*4+3] = UInt8(max(0, min(255, a * 255)))
            }
        }

        guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = CGContext(
                data: &rgba, width: srcW, height: srcH,
                bitsPerComponent: 8, bytesPerRow: srcW * 4,
                space: colorSpace,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              ),
              let cgImage = ctx.makeImage() else { return nil }

        // Scale down to thumbnail size — draw into a context of the target size
        guard let thumbCtx = CGContext(
            data: nil, width: thumbW, height: thumbH,
            bitsPerComponent: 8, bytesPerRow: thumbW * 4,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }

        thumbCtx.interpolationQuality = .high
        thumbCtx.draw(cgImage, in: CGRect(x: 0, y: 0, width: thumbW, height: thumbH))
        guard let thumbCG = thumbCtx.makeImage() else { return nil }

        return NSImage(cgImage: thumbCG, size: NSSize(width: thumbW, height: thumbH))
    }

    private static func float16ToFloat(_ h: UInt16) -> Float {
        let sign = (h >> 15) & 0x1
        let exp = (h >> 10) & 0x1F
        let mant = h & 0x3FF
        if exp == 0 {
            if mant == 0 { return sign == 1 ? -0.0 : 0.0 }
            return (sign == 1 ? -1.0 : 1.0) * Float(mant) / 1024.0 * pow(2.0, -14.0)
        }
        if exp == 31 { return mant == 0 ? (sign == 1 ? -.infinity : .infinity) : .nan }
        return (sign == 1 ? -1.0 : 1.0) * (1.0 + Float(mant) / 1024.0) * pow(2.0, Float(exp) - 15.0)
    }

    /// Update the thumbnail for the given layer. Call after strokes / moves / deletes.
    func updateThumbnail(for layer: Layer) {
        let thumb = generateThumbnail(for: layer)
        DispatchQueue.main.async {
            layer.thumbnail = thumb
        }
    }

    /// Update thumbnails for all layers. Call on initial load.
    func updateAllThumbnails(in layerStack: LayerStack) {
        for layer in layerStack.layers {
            updateThumbnail(for: layer)
        }
    }

    // MARK: - Image Import (Stock Photos)

    /// Decode image data, scale to fit canvas preserving aspect, center, and upload to the layer's texture.
    func fillLayerWithImageFitToCanvas(imageData: Data, layer: Layer) throws {
        guard let nsImage = NSImage(data: imageData),
              let cgImage = nsImage.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            throw NSError(domain: "Artsy", code: -1, userInfo: [NSLocalizedDescriptionKey: "Could not decode image"])
        }

        let canvasW = layer.texture.width
        let canvasH = layer.texture.height
        let imgW = CGFloat(cgImage.width)
        let imgH = CGFloat(cgImage.height)

        // Compute fit-to-canvas rect (preserve aspect, center)
        let scale = min(CGFloat(canvasW) / imgW, CGFloat(canvasH) / imgH)
        let fitW = imgW * scale
        let fitH = imgH * scale
        let fitRect = CGRect(
            x: (CGFloat(canvasW) - fitW) / 2,
            y: (CGFloat(canvasH) - fitH) / 2,
            width: fitW,
            height: fitH
        )

        // Rasterize into a canvas-sized CGContext (P3 to match pipeline)
        guard let colorSpace = CGColorSpace(name: CGColorSpace.displayP3),
              let cgContext = CGContext(
                data: nil, width: canvasW, height: canvasH,
                bitsPerComponent: 8, bytesPerRow: canvasW * 4,
                space: colorSpace,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              ) else {
            throw NSError(domain: "Artsy", code: -1, userInfo: [NSLocalizedDescriptionKey: "Could not create bitmap context"])
        }

        cgContext.interpolationQuality = .high
        cgContext.draw(cgImage, in: fitRect)

        guard let finalImage = cgContext.makeImage() else {
            throw NSError(domain: "Artsy", code: -1, userInfo: [NSLocalizedDescriptionKey: "Could not finalize image"])
        }

        CanvasDocument.loadCGImageIntoTexture(cgImage: finalImage, texture: layer.texture, context: context)
    }

    // MARK: - Shape Drawing

    private var shapeStagingTexture: MTLTexture?

    /// Rasterize a shape path into the active layer. CPU work is fast; GPU work
    /// runs in a single command buffer so the main thread never waits.
    func drawShape(
        path: CGPath,
        strokeColor: StrokeColor?,
        fillColor: StrokeColor?,
        strokeWidth: CGFloat,
        layer: Layer,
        context: MetalContext
    ) {
        let w = layer.texture.width
        let h = layer.texture.height

        // Use Display P3 to match the color picker's default color space on Macs
        guard let colorSpace = CGColorSpace(name: CGColorSpace.displayP3),
              let cgContext = CGContext(
                data: nil, width: w, height: h,
                bitsPerComponent: 8, bytesPerRow: w * 4,
                space: colorSpace,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              ) else { return }

        cgContext.setShouldAntialias(true)

        if let fill = fillColor {
            cgContext.addPath(path)
            cgContext.setFillColor(CGColor(
                colorSpace: colorSpace,
                components: [CGFloat(fill.red), CGFloat(fill.green), CGFloat(fill.blue), CGFloat(fill.alpha)]
            )!)
            cgContext.fillPath()
        }
        if let stroke = strokeColor {
            cgContext.addPath(path)
            cgContext.setStrokeColor(CGColor(
                colorSpace: colorSpace,
                components: [CGFloat(stroke.red), CGFloat(stroke.green), CGFloat(stroke.blue), CGFloat(stroke.alpha)]
            )!)
            cgContext.setLineWidth(strokeWidth)
            cgContext.setLineJoin(.round)
            cgContext.setLineCap(.round)
            cgContext.strokePath()
        }

        guard let cgImage = cgContext.makeImage() else { return }

        // Convert pixel data to rgba16Float for upload
        guard let staging = prepareShapeStaging(width: w, height: h) else { return }

        // Draw CGImage into a bitmap and upload directly (no CanvasDocument helper — we need async)
        uploadCGImageAndComposite(
            cgImage: cgImage,
            staging: staging,
            destination: layer.texture,
            context: context
        )
    }

    private func prepareShapeStaging(width: Int, height: Int) -> MTLTexture? {
        if let existing = shapeStagingTexture, existing.width == width, existing.height == height {
            return existing
        }
        let tex = try? textureManager.makeCanvasTexture(width: width, height: height, label: "ShapeStaging")
        shapeStagingTexture = tex
        return tex
    }

    /// Upload a CGImage to a staging texture and composite onto the destination,
    /// all in a single GPU submission with no main-thread wait.
    private func uploadCGImageAndComposite(
        cgImage: CGImage,
        staging: MTLTexture,
        destination: MTLTexture,
        context: MetalContext
    ) {
        let w = staging.width
        let h = staging.height

        // Render CGImage into a bitmap context with premultiplied RGBA8 — P3 to match picker
        guard let colorSpace = CGColorSpace(name: CGColorSpace.displayP3),
              let ctx = CGContext(
                data: nil, width: w, height: h,
                bitsPerComponent: 8, bytesPerRow: w * 4,
                space: colorSpace,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              ) else { return }
        ctx.draw(cgImage, in: CGRect(x: 0, y: 0, width: w, height: h))
        guard let rgba8 = ctx.data else { return }

        // Convert RGBA8 → RGBA16Float
        let pixelCount = w * h
        var f16Buffer = [UInt16](repeating: 0, count: pixelCount * 4)
        let bytes = rgba8.assumingMemoryBound(to: UInt8.self)
        for i in 0..<pixelCount {
            f16Buffer[i*4+0] = floatToFloat16(Float(bytes[i*4+0]) / 255.0)
            f16Buffer[i*4+1] = floatToFloat16(Float(bytes[i*4+1]) / 255.0)
            f16Buffer[i*4+2] = floatToFloat16(Float(bytes[i*4+2]) / 255.0)
            f16Buffer[i*4+3] = floatToFloat16(Float(bytes[i*4+3]) / 255.0)
        }

        // Upload via shared texture → blit to private staging → composite — all in ONE command buffer
        guard let shared = try? textureManager.makeSharedTexture(width: w, height: h, label: "ShapeSharedUpload") else { return }
        f16Buffer.withUnsafeBytes { raw in
            shared.replace(
                region: MTLRegion(origin: .init(x: 0, y: 0, z: 0), size: .init(width: w, height: h, depth: 1)),
                mipmapLevel: 0,
                withBytes: raw.baseAddress!,
                bytesPerRow: w * 8
            )
        }

        guard let cb = context.commandQueue.makeCommandBuffer() else { return }

        // Clear staging, copy shared → staging, composite staging → destination
        textureManager.clearTexture(staging, commandBuffer: cb)
        if let blit = cb.makeBlitCommandEncoder() {
            blit.copy(from: shared, to: staging)
            blit.endEncoding()
        }
        compositor.compositeNormal(source: staging, onto: destination, opacity: 1.0, commandBuffer: cb)

        cb.commit()
        // No waitUntilCompleted — the next frame's render loop will see the final result
    }

    private func floatToFloat16(_ f: Float) -> UInt16 {
        let bits = f.bitPattern
        let sign = (bits >> 31) & 0x1
        let exp = Int((bits >> 23) & 0xFF) - 127
        let mant = bits & 0x7FFFFF
        if exp > 15 { return UInt16(sign << 15 | 0x1F << 10) }
        if exp < -14 { return UInt16(sign << 15) }
        let hExp = UInt16(exp + 15)
        let hMant = UInt16(mant >> 13)
        return UInt16(sign << 15) | (hExp << 10) | hMant
    }

    // MARK: - Selection Operations

    func clearInsideSelection(path: CGPath, layer: Layer, context: MetalContext) {
        let w = layer.texture.width
        let h = layer.texture.height

        // Rasterize mask
        guard let maskTexture = createMaskTexture(path: path, width: w, height: h, context: context) else { return }

        // Run compute shader
        guard let commandBuffer = context.commandQueue.makeCommandBuffer(),
              let encoder = commandBuffer.makeComputeCommandEncoder() else { return }

        encoder.setComputePipelineState(context.maskedClearPipelineState)
        encoder.setTexture(layer.texture, index: 0)
        encoder.setTexture(maskTexture, index: 1)

        let threadGroupSize = MTLSize(width: 16, height: 16, depth: 1)
        let threadGroups = MTLSize(width: (w + 15) / 16, height: (h + 15) / 16, depth: 1)
        encoder.dispatchThreadgroups(threadGroups, threadsPerThreadgroup: threadGroupSize)
        encoder.endEncoding()

        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()
    }

    private func createMaskTexture(path: CGPath, width: Int, height: Int, context: MetalContext) -> MTLTexture? {
        guard let cgContext = CGContext(
            data: nil, width: width, height: height,
            bitsPerComponent: 8, bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }

        cgContext.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        cgContext.addPath(path)
        cgContext.fillPath()

        guard let data = cgContext.data else { return nil }

        let desc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba8Unorm, width: width, height: height, mipmapped: false
        )
        desc.usage = [.shaderRead]
        #if arch(arm64)
        desc.storageMode = .shared
        #else
        desc.storageMode = .managed
        #endif

        guard let texture = context.device.makeTexture(descriptor: desc) else { return nil }
        texture.replace(
            region: MTLRegion(origin: .init(x: 0, y: 0, z: 0), size: .init(width: width, height: height, depth: 1)),
            mipmapLevel: 0, withBytes: data, bytesPerRow: width * 4
        )
        return texture
    }

    // MARK: - Stroke Lifecycle

    func beginStroke() {
        lastRenderedPointCount = 0
        guard let commandBuffer = context.commandQueue.makeCommandBuffer() else { return }
        textureManager.clearTexture(activeStrokeTexture, commandBuffer: commandBuffer)
        commandBuffer.commit()
    }

    func finalizeStroke() {
        guard let viewModel = viewModel,
              let layerStack = viewModel.layerStack,
              let activeLayer = layerStack.activeLayer else { return }

        let isErasing = viewModel.currentBrush.category == .utility

        guard let commandBuffer = context.commandQueue.makeCommandBuffer() else { return }

        if !isErasing {
            // Normal brush: merge active stroke texture into layer
            compositor.compositeNormal(
                source: activeStrokeTexture,
                onto: activeLayer.texture,
                opacity: 1.0,
                commandBuffer: commandBuffer
            )
        }
        // Eraser already rendered directly onto the layer — nothing to merge

        textureManager.clearTexture(activeStrokeTexture, commandBuffer: commandBuffer)
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()
        lastRenderedPointCount = 0

        // Update thumbnail off the main thread to avoid blocking drawing
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            self?.updateThumbnail(for: activeLayer)
        }
    }

    func rerenderLayer(strokes: [Stroke], layerTexture: MTLTexture) {
        guard let commandBuffer = context.commandQueue.makeCommandBuffer() else { return }
        textureManager.clearTexture(layerTexture, commandBuffer: commandBuffer)

        for stroke in strokes {
            if let points = stroke.interpolatedPoints, !points.isEmpty {
                strokeRenderer.render(
                    points: points,
                    brush: stroke.brushDescriptor,
                    color: stroke.color,
                    targetTexture: layerTexture,
                    commandBuffer: commandBuffer,
                    canvasSize: canvasSize
                )
            }
        }

        commandBuffer.commit()
    }
}
