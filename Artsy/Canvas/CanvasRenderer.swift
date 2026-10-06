import Metal
import MetalKit

final class CanvasRenderer: NSObject, MTKViewDelegate {
    let context: MetalContext
    let textureManager: TextureManager
    let strokeRenderer: StrokeRenderer
    let compositor: CompositorPipeline

    // Canvas textures
    /// The in-progress stroke is split across two textures. This one holds the part that
    /// has settled and is drawn once; `strokeTailTexture` holds the newest part, which is
    /// redrawn every frame because the next pen sample can still reshape it.
    var activeStrokeTexture: MTLTexture!
    var strokeTailTexture: MTLTexture!
    var compositeTexture: MTLTexture!
    var blendTempTexture: MTLTexture!

    let canvasSize: CGSize
    weak var viewModel: CanvasViewModel?

    private var hasInitializedTransform = false

    // In-progress stroke. Regions are texture pixels (origin top-left).
    /// Ribbon brushes: index of the last path point whose geometry is in `activeStrokeTexture`.
    private var committedThrough: Int?
    /// Stamp brushes: where along the path the next settled dab goes.
    private var dabPlacer: DabPlacer?
    /// Stamp brushes that spray while resting: dabs already laid per rest, by sample index.
    private var restDabsLaid: [Int: Int] = [:]
    private var renderedRevision = 0
    /// Where the tail was drawn last frame.
    private var tailRegions: [MTLScissorRect] = []
    /// Everything drawn into `activeStrokeTexture` by this stroke.
    private var strokeRegion: MTLScissorRect?
    /// What has changed since `compositeTexture` was last brought up to date.
    private var pendingRegions: [MTLScissorRect] = []
    /// The scene `compositeTexture` currently shows, while a stroke is in progress.
    private var compositeSignature: CompositeSignature?

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
        strokeTailTexture = try textureManager.makeCanvasTexture(width: w, height: h, label: "Stroke Tail")
        compositeTexture = try textureManager.makeCanvasTexture(width: w, height: h, label: "Composite")
        blendTempTexture = try textureManager.makeCanvasTexture(width: w, height: h, label: "Blend Temp")

        guard let commandBuffer = context.commandQueue.makeCommandBuffer() else { return }
        textureManager.clearTexture(activeStrokeTexture, commandBuffer: commandBuffer)
        textureManager.clearTexture(strokeTailTexture, commandBuffer: commandBuffer)
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
              viewModel.layerStack != nil,
              let drawable = view.currentDrawable,
              let commandBuffer = context.commandQueue.makeCommandBuffer() else {
            return
        }

        if !hasInitializedTransform && view.bounds.size.width > 0 {
            viewModel.transform.zoomToFit(canvasSize: canvasSize, viewSize: view.bounds.size)
            hasInitializedTransform = true
        }

        // NSEvent timestamps are system uptime, so the rest is measured on the same clock
        viewModel.holdStroke(at: ProcessInfo.processInfo.systemUptime)
        encodeFrame(into: commandBuffer)

        // Display
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

    /// Encode everything up to `compositeTexture`: the in-progress stroke, then every layer.
    /// Separate from `draw(in:)` so a frame can be rendered without a view (tests, stroke replay).
    func encodeFrame(into commandBuffer: MTLCommandBuffer) {
        guard let viewModel = viewModel, let layerStack = viewModel.layerStack else { return }

        encodeActiveStroke(into: commandBuffer)

        // While the pen is down, only the pixels the stroke touched since the last frame can
        // have changed — provided nothing else about the scene did. Otherwise redo all of it.
        let signature = CompositeSignature(viewModel: viewModel, layerStack: layerStack)
        let strokeOnly = viewModel.isDrawing && viewModel.transformSession == nil && viewModel.floatingTexture == nil
        let regions: [MTLScissorRect]? =
            strokeOnly && signature == compositeSignature ? Self.disjoint(pendingRegions) : nil
        compositeSignature = strokeOnly ? signature : nil
        pendingRegions.removeAll()

        if let regions {
            guard !regions.isEmpty else { return }
            compositor.clear(compositeTexture, regions: regions, commandBuffer: commandBuffer)
        } else {
            textureManager.clearTexture(compositeTexture, commandBuffer: commandBuffer)
        }

        let stroke = viewModel.isDrawing ? strokeOverlay(for: viewModel) : nil

        for (i, layer) in layerStack.layers.enumerated() {
            guard layer.isVisible else { continue }
            let isActive = i == layerStack.activeLayerIndex

            compositor.compositeLayer(
                source: layer.texture,
                onto: compositeTexture,
                opacity: layer.opacity,
                // Bottom layer always uses normal blending (no destination to blend with)
                blendMode: i == 0 ? .normal : layer.blendMode,
                stroke: isActive ? stroke : nil,
                tempTexture: blendTempTexture,
                regions: regions,
                commandBuffer: commandBuffer
            )

            if isActive {
                // Transform tool preview — composite the source snapshot warped by
                // the session's current affine transform over its sourceBounds.
                if let session = viewModel.transformSession, session.targetLayer.id == layer.id {
                    compositor.compositeWithAffineTransform(
                        source: session.sourceTexture,
                        sourceRect: session.sourceBounds,
                        onto: compositeTexture,
                        canvasSize: canvasSize,
                        transform: session.currentTransform,
                        opacity: layer.opacity,
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
    }

    /// Bring the stroke textures up to date with the pen samples received so far.
    ///
    /// Points that have settled are drawn into `activeStrokeTexture` once and never again;
    /// the rest (the tail) is redrawn into `strokeTailTexture`. That keeps the cost of a
    /// frame independent of how long the stroke already is.
    ///
    /// - Parameter finishing: the pen has lifted, so every point is settled.
    private func encodeActiveStroke(into commandBuffer: MTLCommandBuffer, finishing: Bool = false) {
        guard let viewModel = viewModel, viewModel.isDrawing, let path = viewModel.activePath else { return }
        guard finishing || path.revision != renderedRevision else { return }
        renderedRevision = path.revision

        let points = path.points
        guard !points.isEmpty else { return }

        let brush = viewModel.currentBrush
        // An eraser stroke is built like any other; its coverage is subtracted when it is
        // merged, so the colour is irrelevant.
        let color = brush.category == .utility ? StrokeColor.white : viewModel.currentColor
        let mirrors = SymmetryTransform.transforms(mode: viewModel.symmetryMode, canvasSize: canvasSize)
        let renderer = strokeRenderer
        let size = canvasSize

        // What goes into each stroke texture this frame: closures that draw into an open
        // render pass and return the canvas bounds they covered.
        typealias Draw = (MTLRenderCommandEncoder) -> [CGRect]
        var drawSettled: Draw?
        var drawTail: Draw?

        switch brush.rendering {
        case .ribbon:
            let nothingCommitted = committedThrough == nil
            let from = committedThrough ?? 0
            // Stop one short of the last settled point so the ribbon's edge where this piece
            // ends is computed from settled neighbours on both sides — the next piece then
            // starts from exactly the same edge.
            let settleThrough = finishing ? points.count - 1 : path.settledCount - 2
            if finishing || settleThrough > from {
                drawSettled = { encoder in
                    renderer.encode(points: points, range: from...settleThrough, brush: brush, color: color,
                                    startCap: nothingCommitted, endCap: finishing,
                                    mirrors: mirrors, encoder: encoder, canvasSize: size)
                }
                committedThrough = settleThrough
            }
            if !finishing {
                let tailStart = committedThrough ?? 0
                let tailHasStartCap = committedThrough == nil
                drawTail = { encoder in
                    renderer.encode(points: points, range: tailStart...(points.count - 1), brush: brush, color: color,
                                    startCap: tailHasStartCap, endCap: true,
                                    mirrors: mirrors, encoder: encoder, canvasSize: size)
                }
            }

        case .stamp(let settings):
            // A build-up brush has no cap on the stroke, so the brush's and the slider's
            // opacity go into every dab; a wash applies them once, when the stroke merges.
            let dabScale = settings.accumulation == .buildUp ? brush.opacity * viewModel.brushOpacity : 1
            let pathEnd = points[points.count - 1].distance
            var placer = dabPlacer ?? DabPlacer(strokeSeed: Self.strokeSeed(for: path))

            // Dabs that sit on settled path are final: lay them for good.
            let settledEnd = finishing ? pathEnd : (path.settledCount > 0 ? points[path.settledCount - 1].distance : nil)
            var dabs = settledEnd.map { placer.dabs(along: points, upTo: $0, brush: brush, settings: settings) } ?? []

            // A pen resting on the paper keeps an airbrush spraying. Time has passed, so
            // those dabs are final too; they go on the sample the pen rested on, which
            // never moves. A rest the pen has moved on from gets whatever it is still owed,
            // so the result does not depend on when frames happened to run.
            if settings.holdRate > 0 {
                for rest in path.rests + (path.currentRest.map { [$0] } ?? []) {
                    let wanted = Int(rest.duration * Double(settings.holdRate))
                    let laid = restDabsLaid[rest.sampleIndex] ?? 0
                    guard wanted > laid, let index = path.pointIndex(forSample: rest.sampleIndex) else { continue }
                    dabs += placer.restingDabs(at: points[index], count: wanted - laid, settings: settings)
                    restDabsLaid[rest.sampleIndex] = wanted
                }
            }

            if !dabs.isEmpty {
                drawSettled = { encoder in
                    renderer.encode(dabs: dabs, brush: brush, settings: settings, color: color, opacityScale: dabScale,
                                    mirrors: mirrors, encoder: encoder, canvasSize: size)
                }
            }
            dabPlacer = placer

            // The rest are laid with a copy of the placer, so next frame starts over from
            // the same place.
            if !finishing {
                var tailPlacer = placer
                let dabs = tailPlacer.dabs(along: points, upTo: pathEnd, brush: brush, settings: settings)
                if !dabs.isEmpty {
                    drawTail = { encoder in
                        renderer.encode(dabs: dabs, brush: brush, settings: settings, color: color, opacityScale: dabScale,
                                        mirrors: mirrors, encoder: encoder, canvasSize: size)
                    }
                }
            }
        }

        // 1. Newly settled parts go into the stroke texture, once.
        var committedRegions: [MTLScissorRect] = []
        if let drawSettled {
            let pass = MTLRenderPassDescriptor()
            pass.colorAttachments[0].texture = activeStrokeTexture
            pass.colorAttachments[0].loadAction = .load
            pass.colorAttachments[0].storeAction = .store
            if let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: pass) {
                committedRegions = drawSettled(encoder).compactMap(region(for:))
                encoder.endEncoding()
            }
            for region in committedRegions {
                strokeRegion = strokeRegion.map { Self.union($0, region) } ?? region
            }
        }

        // 2. The tail: erase last frame's, draw this frame's.
        var newTailRegions: [MTLScissorRect] = []
        if !tailRegions.isEmpty || drawTail != nil {
            let pass = MTLRenderPassDescriptor()
            pass.colorAttachments[0].texture = strokeTailTexture
            pass.colorAttachments[0].loadAction = .load
            pass.colorAttachments[0].storeAction = .store
            if let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: pass) {
                compositor.encodeClear(regions: tailRegions, in: encoder, of: strokeTailTexture)
                if let drawTail {
                    newTailRegions = drawTail(encoder).compactMap(region(for:))
                }
                encoder.endEncoding()
            }
        }

        pendingRegions += committedRegions + tailRegions + newTailRegions
        tailRegions = newTailRegions
    }

    /// A number that differs from stroke to stroke but is the same when a stroke is replayed.
    private static func strokeSeed(for path: StrokePath) -> UInt64 {
        guard let first = path.samples.first else { return 0 }
        let x = UInt64(bitPattern: Int64((first.position.x * 16).rounded()))
        let y = UInt64(bitPattern: Int64((first.position.y * 16).rounded()))
        return x &* 0x9E3779B97F4A7C15 ^ y &* 0xC2B2AE3D27D4EB4F
    }

    /// How the stroke in progress combines with the layer it is on.
    private func strokeOverlay(for viewModel: CanvasViewModel) -> CompositorPipeline.StrokeOverlay {
        let brush = viewModel.currentBrush
        var opacity = viewModel.brushOpacity
        var accumulates = false
        if case .stamp(let settings) = brush.rendering {
            accumulates = true
            opacity = settings.accumulation == .wash ? brush.opacity * viewModel.brushOpacity : 1
        }
        return CompositorPipeline.StrokeOverlay(
            committed: activeStrokeTexture, tail: strokeTailTexture,
            opacity: opacity, erase: brush.category == .utility, accumulates: accumulates
        )
    }

    // MARK: - Regions

    /// Canvas-space bounds (Y up) as a rectangle of texture pixels (Y down), padded so
    /// antialiased edges are inside it. Nil if it misses the canvas.
    private func region(for bounds: CGRect) -> MTLScissorRect? {
        guard !bounds.isNull else { return nil }
        let width = Int(canvasSize.width)
        let height = Int(canvasSize.height)
        let minX = max(0, Int(bounds.minX.rounded(.down)) - 2)
        let maxX = min(width, Int(bounds.maxX.rounded(.up)) + 2)
        let minY = max(0, height - Int(bounds.maxY.rounded(.up)) - 2)
        let maxY = min(height, height - Int(bounds.minY.rounded(.down)) + 2)
        guard maxX > minX, maxY > minY else { return nil }
        return MTLScissorRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }

    private static func union(_ a: MTLScissorRect, _ b: MTLScissorRect) -> MTLScissorRect {
        let minX = min(a.x, b.x), minY = min(a.y, b.y)
        let maxX = max(a.x + a.width, b.x + b.width), maxY = max(a.y + a.height, b.y + b.height)
        return MTLScissorRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }

    private static func intersects(_ a: MTLScissorRect, _ b: MTLScissorRect) -> Bool {
        a.x < b.x + b.width && b.x < a.x + a.width && a.y < b.y + b.height && b.y < a.y + a.height
    }

    /// Merge overlapping rectangles until none overlap. Compositing blends each layer once
    /// per rectangle, so a pixel covered twice would have the layer applied twice.
    static func disjoint(_ regions: [MTLScissorRect]) -> [MTLScissorRect] {
        var result: [MTLScissorRect] = []
        for var region in regions {
            while let index = result.firstIndex(where: { intersects($0, region) }) {
                region = union(region, result.remove(at: index))
            }
            result.append(region)
        }
        return result
    }

    /// What a composite depends on besides the stroke itself. If any of it changes while
    /// the pen is down, the next frame recomposites everything.
    private struct CompositeSignature: Equatable {
        struct LayerState: Equatable {
            let id: UUID
            let isVisible: Bool
            let opacity: Float
            let blendMode: LayerBlendMode
        }
        let layers: [LayerState]
        let activeLayerIndex: Int
        let strokeOpacity: Float
        let brushID: UUID

        init(viewModel: CanvasViewModel, layerStack: LayerStack) {
            layers = layerStack.layers.map {
                LayerState(id: $0.id, isVisible: $0.isVisible, opacity: $0.opacity, blendMode: $0.blendMode)
            }
            activeLayerIndex = layerStack.activeLayerIndex
            strokeOpacity = viewModel.brushOpacity
            brushID = viewModel.currentBrush.id
        }
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
        let layerW = layer.texture.width
        let layerH = layer.texture.height
        let aspect = CGFloat(layerW) / CGFloat(layerH)

        let thumbW: Int
        let thumbH: Int
        if aspect >= 1 {
            thumbW = maxSize
            thumbH = Int(CGFloat(maxSize) / aspect)
        } else {
            thumbH = maxSize
            thumbW = Int(CGFloat(maxSize) * aspect)
        }

        // Shrink the layer on the GPU in 4x steps until it is small, and read back only
        // that. Reading the whole layer to the CPU for a 64 px image costs tens of
        // megabytes and milliseconds after every stroke.
        guard let cb = context.commandQueue.makeCommandBuffer() else { return nil }
        var source = layer.texture
        var levels: [(width: Int, height: Int)] = []
        var levelW = layerW, levelH = layerH
        while max(levelW, levelH) > 256 {
            levelW = max(1, (levelW + 3) / 4)
            levelH = max(1, (levelH + 3) / 4)
            levels.append((levelW, levelH))
        }
        for (index, level) in levels.enumerated() {
            let isLast = index == levels.count - 1
            guard let smaller = try? (isLast
                ? textureManager.makeSharedTexture(width: level.width, height: level.height, label: "ThumbRead")
                : textureManager.makeCanvasTexture(width: level.width, height: level.height, label: "ThumbStep"))
            else { return nil }
            compositor.downsample(source, into: smaller, commandBuffer: cb)
            source = smaller
        }
        if levels.isEmpty {
            // Already small: copy it as it is.
            guard let readable = try? textureManager.makeSharedTexture(width: layerW, height: layerH, label: "ThumbRead"),
                  let blit = cb.makeBlitCommandEncoder() else { return nil }
            blit.copy(from: layer.texture, to: readable)
            blit.endEncoding()
            source = readable
        }
        cb.commit()
        cb.waitUntilCompleted()

        let readable = source
        let srcW = readable.width
        let srcH = readable.height

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
        guard let commandBuffer = context.commandQueue.makeCommandBuffer() else { return }
        // A stroke that never reached finalizeStroke (tool switched mid-drag, say) leaves
        // its pixels behind; a finished one has already cleaned up.
        if let strokeRegion {
            compositor.clear(activeStrokeTexture, regions: [strokeRegion], commandBuffer: commandBuffer)
        }
        compositor.clear(strokeTailTexture, regions: tailRegions, commandBuffer: commandBuffer)
        commandBuffer.commit()
        resetStrokeState()
    }

    private func resetStrokeState() {
        committedThrough = nil
        dabPlacer = nil
        restDabsLaid = [:]
        renderedRevision = 0
        tailRegions = []
        strokeRegion = nil
        pendingRegions = []
        compositeSignature = nil
    }

    /// Merge the finished stroke into the active layer. Call before `viewModel.endStroke()`.
    func finalizeStroke() {
        guard let viewModel = viewModel,
              let layerStack = viewModel.layerStack,
              let activeLayer = layerStack.activeLayer else { return }

        let isErasing = viewModel.currentBrush.category == .utility

        guard let commandBuffer = context.commandQueue.makeCommandBuffer() else { return }

        // Draw the samples that arrived since the last displayed frame, and settle the tail.
        viewModel.settleStroke()
        encodeActiveStroke(into: commandBuffer, finishing: true)

        if let strokeRegion {
            // Undo only needs the pixels this stroke is about to change.
            viewModel.undoManager.saveRegion(
                of: activeLayer, in: layerStack, region: strokeRegion, context: context,
                description: isErasing ? "Erase" : viewModel.currentBrush.name,
                commandBuffer: commandBuffer
            )
            viewModel.markDirty()

            let opacity = strokeOverlay(for: viewModel).opacity
            if isErasing {
                compositor.erase(
                    source: activeStrokeTexture, from: activeLayer.texture,
                    opacity: opacity, regions: [strokeRegion], commandBuffer: commandBuffer
                )
            } else {
                compositor.compositeNormal(
                    source: activeStrokeTexture, onto: activeLayer.texture,
                    opacity: opacity, regions: [strokeRegion], commandBuffer: commandBuffer
                )
            }
            compositor.clear(activeStrokeTexture, regions: [strokeRegion], commandBuffer: commandBuffer)
        }

        commandBuffer.commit()
        resetStrokeState()

        // Update thumbnail off the main thread to avoid blocking drawing
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            self?.updateThumbnail(for: activeLayer)
        }
    }
}
