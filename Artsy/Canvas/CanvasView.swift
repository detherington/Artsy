import AppKit
import Combine
import MetalKit

class CanvasView: MTKView {

    var viewModel: CanvasViewModel!
    var renderer: CanvasRenderer!

    private var isSpaceHeld = false
    private var isPanning = false
    private var lastPanPoint: CGPoint = .zero
    private var previousBrush: BrushDescriptor?

    // Selection drag state
    private var selectionAnchor: CGPoint?
    private var selectionDragPoints: [CGPoint] = []

    // Move-within-selection state
    private var moveLastCanvasPoint: CGPoint?
    private var isMovingSelection = false
    private let selectionMoveHandler = SelectionMoveHandler()

    // Shape drag state
    private var shapeAnchor: CGPoint?
    private var shapeFreeformPoints: [CGPoint] = []

    // Transform drag state
    private var transformHandle: TransformHandle = .none
    private var transformDragStart: CGPoint?
    private var transformStartTransform: CGAffineTransform = .identity
    private var toolChangeObservation: AnyCancellable?

    override var acceptsFirstResponder: Bool { true }

    func configure(context: MetalContext, viewModel: CanvasViewModel) throws {
        self.device = context.device
        self.viewModel = viewModel

        // Use Display P3 to match the macOS color picker's default color space.
        // .bgra8Unorm (non-gamma-encoded) means stored pixel values pass through
        // to the display without double-gamma-encoding.
        self.colorPixelFormat = .bgra8Unorm
        self.colorspace = CGColorSpace(name: CGColorSpace.displayP3)
        self.preferredFramesPerSecond = 120
        self.isPaused = false
        self.enableSetNeedsDisplay = false
        self.clearColor = MTLClearColor(red: 0.18, green: 0.18, blue: 0.18, alpha: 1.0)

        let canvasRenderer = try CanvasRenderer(context: context, canvasSize: viewModel.canvasSize)
        canvasRenderer.viewModel = viewModel
        try canvasRenderer.setupLayerStack(for: viewModel)
        self.renderer = canvasRenderer
        self.delegate = canvasRenderer

        // Handle tool transitions:
        //   • switching TO .transform → start a session immediately so the
        //     handles appear on the canvas without waiting for a mouse click
        //   • switching AWAY from .transform → auto-commit any pending session
        //     synchronously so a mouseDown in the next tool can't land mid-commit
        toolChangeObservation = viewModel.$currentTool
            .dropFirst()
            .sink { [weak self] newTool in
                guard let self = self else { return }
                if newTool == .transform {
                    self.ensureTransformSession()
                    self.redrawOverlays()
                } else if self.viewModel.transformSession != nil {
                    self.commitTransformIfNeeded()
                }
            }
    }

    // MARK: - Mouse Down

    override func mouseDown(with event: NSEvent) {
        guard let viewModel = viewModel, let renderer = renderer else { return }

        // Space+drag always pans regardless of tool
        if isSpaceHeld || event.modifierFlags.contains(.option) {
            isPanning = true
            lastPanPoint = event.locationInWindow
            return
        }

        switch viewModel.currentTool {
        case .pan:
            isPanning = true
            lastPanPoint = event.locationInWindow
            NSCursor.closedHand.set()

        case .selection:
            let viewPoint = convert(event.locationInWindow, from: nil)
            let canvasPoint = viewModel.transform.viewToCanvas(viewPoint, viewSize: bounds.size)

            // If clicking inside an existing selection, cut and start moving content
            if let path = viewModel.selectionPath, path.contains(canvasPoint) {
                isMovingSelection = true
                moveLastCanvasPoint = canvasPoint
                viewModel.saveUndoSnapshot(renderer: renderer, description: "Move Selection")

                if let activeLayer = viewModel.layerStack?.activeLayer {
                    selectionMoveHandler.begin(
                        selectionPath: path,
                        layer: activeLayer,
                        context: renderer.context,
                        textureManager: renderer.textureManager
                    )
                    viewModel.floatingTexture = selectionMoveHandler.floatingTexture
                    viewModel.floatingOffset = .zero
                }
                NSCursor.closedHand.set()
                return
            }

            // Otherwise, start a new selection — save undo so the selection itself can be undone
            viewModel.saveUndoSnapshot(renderer: renderer, description: "Select")
            selectionAnchor = canvasPoint
            selectionDragPoints = [canvasPoint]
            viewModel.clearSelection()

        case .brush, .eraser:
            handleDrawingMouseDown(event)

        case .shape:
            let viewPoint = convert(event.locationInWindow, from: nil)
            let canvasPoint = viewModel.transform.viewToCanvas(viewPoint, viewSize: bounds.size)
            shapeAnchor = canvasPoint
            shapeFreeformPoints = [canvasPoint]
            updateShapePreview(to: canvasPoint)

        case .eyedropper:
            handleEyedropperMouseDown(event)

        case .fill:
            handleFillMouseDown(event)

        case .transform:
            handleTransformMouseDown(event)
        }
    }

    // MARK: - Mouse Dragged

    override func mouseDragged(with event: NSEvent) {
        guard let viewModel = viewModel else { return }

        if isPanning {
            let currentPoint = event.locationInWindow
            let delta = CGPoint(
                x: currentPoint.x - lastPanPoint.x,
                y: currentPoint.y - lastPanPoint.y
            )
            viewModel.transform.pan(by: delta)
            lastPanPoint = currentPoint
            return
        }

        switch viewModel.currentTool {
        case .selection where isMovingSelection:
            let viewPoint = convert(event.locationInWindow, from: nil)
            let canvasPoint = viewModel.transform.viewToCanvas(viewPoint, viewSize: bounds.size)
            handleMoveDrag(to: canvasPoint)
            return

        case .selection:
            let viewPoint = convert(event.locationInWindow, from: nil)
            let canvasPoint = viewModel.transform.viewToCanvas(viewPoint, viewSize: bounds.size)
            updateSelectionDrag(to: canvasPoint)

        case .brush, .eraser:
            handleDrawingMouseDragged(event)

        case .shape:
            let viewPoint = convert(event.locationInWindow, from: nil)
            let canvasPoint = viewModel.transform.viewToCanvas(viewPoint, viewSize: bounds.size)
            updateShapePreview(to: canvasPoint)

        case .transform:
            handleTransformMouseDragged(event)

        default:
            break
        }
    }

    // MARK: - Mouse Up

    override func mouseUp(with event: NSEvent) {
        guard let viewModel = viewModel, let renderer = renderer else { return }

        if isPanning {
            isPanning = false
            if viewModel.currentTool == .pan {
                NSCursor.openHand.set()
            }
            return
        }

        switch viewModel.currentTool {
        case .selection where isMovingSelection:
            // Stamp the floating content at the new position
            if let activeLayer = viewModel.layerStack?.activeLayer {
                selectionMoveHandler.commit(
                    layer: activeLayer,
                    context: renderer.context,
                    textureManager: renderer.textureManager,
                    compositor: renderer.compositor
                )
                renderer.updateThumbnail(for: activeLayer)
            }
            viewModel.floatingTexture = nil
            viewModel.floatingOffset = .zero
            moveLastCanvasPoint = nil
            isMovingSelection = false
            NSCursor.crosshair.set()
            return

        case .selection:
            finalizeSelection()

        case .brush, .eraser:
            handleDrawingMouseUp(event)

        case .shape:
            commitShape()

        case .transform:
            handleTransformMouseUp(event)

        default:
            break
        }
    }

    // MARK: - Drawing Event Helpers

    private func handleDrawingMouseDown(_ event: NSEvent) {
        guard let viewModel = viewModel, let renderer = renderer else { return }

        if let layer = viewModel.layerStack?.activeLayer, layer.isLocked {
            NSSound.beep()
            return
        }

        // Check eraser state from proximity tracking
        if TabletEventHandler.isEraserActive {
            if previousBrush == nil {
                previousBrush = viewModel.currentBrush
            }
            viewModel.currentBrush = .eraser
            viewModel.currentTool = .eraser
        } else if let prev = previousBrush {
            viewModel.currentBrush = prev
            viewModel.currentTool = .brush
            previousBrush = nil
        }

        let point = TabletEventHandler.strokePoint(from: event, in: self)
        let canvasPoint = viewToCanvasPoint(point)

        let brushName = viewModel.currentBrush.category == .utility ? "Erase" : viewModel.currentBrush.name
        viewModel.saveUndoSnapshot(renderer: renderer, description: brushName)

        renderer.beginStroke()
        viewModel.beginStroke(point: canvasPoint)
    }

    private func handleDrawingMouseDragged(_ event: NSEvent) {
        guard let viewModel = viewModel else { return }

        let point = TabletEventHandler.strokePoint(from: event, in: self)
        let canvasPoint = viewToCanvasPoint(point)
        viewModel.continueStroke(point: canvasPoint)
    }

    private func handleDrawingMouseUp(_ event: NSEvent) {
        guard let viewModel = viewModel, let renderer = renderer else { return }

        let _ = viewModel.endStroke()
        renderer.finalizeStroke()
    }

    // MARK: - Eyedropper Tool

    private func handleEyedropperMouseDown(_ event: NSEvent) {
        guard let viewModel = viewModel, let renderer = renderer,
              let composite = renderer.compositeTexture else { return }

        let viewPoint = convert(event.locationInWindow, from: nil)
        let canvasPoint = viewModel.transform.viewToCanvas(viewPoint, viewSize: bounds.size)

        let cs = viewModel.canvasSize
        guard canvasPoint.x >= 0, canvasPoint.x < cs.width,
              canvasPoint.y >= 0, canvasPoint.y < cs.height else { return }

        // Canvas coords (Y-up) → texture coords (Y-down)
        let tx = Int(canvasPoint.x.rounded())
        let ty = Int((cs.height - canvasPoint.y).rounded())
        guard tx >= 0, tx < composite.width, ty >= 0, ty < composite.height else { return }

        // Sample a single pixel — 1×1 staging texture, tiny blit, brief wait is fine.
        guard let staging = try? renderer.textureManager.makeSharedTexture(
            width: 1, height: 1, label: "Eyedropper"
        ),
        let cmdBuf = renderer.context.commandQueue.makeCommandBuffer(),
        let blit = cmdBuf.makeBlitCommandEncoder() else { return }

        blit.copy(
            from: composite,
            sourceSlice: 0,
            sourceLevel: 0,
            sourceOrigin: MTLOrigin(x: tx, y: ty, z: 0),
            sourceSize: MTLSize(width: 1, height: 1, depth: 1),
            to: staging,
            destinationSlice: 0,
            destinationLevel: 0,
            destinationOrigin: MTLOrigin(x: 0, y: 0, z: 0)
        )
        blit.endEncoding()
        cmdBuf.commit()
        cmdBuf.waitUntilCompleted()

        var f16: [UInt16] = [0, 0, 0, 0]
        f16.withUnsafeMutableBytes { raw in
            staging.getBytes(
                raw.baseAddress!,
                bytesPerRow: 8,
                from: MTLRegion(
                    origin: MTLOrigin(x: 0, y: 0, z: 0),
                    size: MTLSize(width: 1, height: 1, depth: 1)
                ),
                mipmapLevel: 0
            )
        }

        let r = Float(Float16(bitPattern: f16[0]))
        let g = Float(Float16(bitPattern: f16[1]))
        let b = Float(Float16(bitPattern: f16[2]))
        // Clamp alpha to 1 — picked color is meant to be applied opaquely.
        let a: Float = 1.0
        let picked = StrokeColor(
            red: max(0, min(1, r)),
            green: max(0, min(1, g)),
            blue: max(0, min(1, b)),
            alpha: a
        )
        viewModel.foregroundColor = picked
        viewModel.currentColor = picked

        // Switch back to brush — common UX convention.
        viewModel.currentTool = .brush
    }

    // MARK: - Transform Tool

    /// Ensure a TransformSession exists for the active layer. Starts one if
    /// missing. If a selection is active, only its pixels get transformed;
    /// otherwise the whole layer is transformed.
    private func ensureTransformSession() {
        guard let viewModel = viewModel, let renderer = renderer else { return }
        if viewModel.transformSession != nil { return }
        guard let layer = viewModel.layerStack?.activeLayer else { return }
        if layer.isLocked { NSSound.beep(); return }

        let selectionPath = viewModel.selectionPath
        viewModel.saveUndoSnapshot(renderer: renderer, description: "Transform")

        viewModel.transformSession = TransformSession.begin(
            targetLayer: layer,
            canvasSize: viewModel.canvasSize,
            selectionPath: selectionPath,
            context: renderer.context,
            textureManager: renderer.textureManager
        )

        // Selection is consumed by the cut — the pixels are now floating in
        // the session's source texture. Clear the marquee so marching ants
        // don't visually duplicate the bounding box.
        if selectionPath != nil {
            viewModel.selectionPath = nil
        }
    }

    private func handleTransformMouseDown(_ event: NSEvent) {
        guard let viewModel = viewModel else { return }
        ensureTransformSession()
        guard let session = viewModel.transformSession else { return }

        let viewPoint = convert(event.locationInWindow, from: nil)
        let canvasPoint = viewModel.transform.viewToCanvas(viewPoint, viewSize: bounds.size)

        transformHandle = hitTestTransformHandle(at: canvasPoint, session: session)
        transformDragStart = canvasPoint
        transformStartTransform = session.currentTransform
    }

    private func handleTransformMouseDragged(_ event: NSEvent) {
        guard let viewModel = viewModel,
              let session = viewModel.transformSession,
              let start = transformDragStart,
              transformHandle != .none else { return }

        let viewPoint = convert(event.locationInWindow, from: nil)
        let canvasPoint = viewModel.transform.viewToCanvas(viewPoint, viewSize: bounds.size)
        let shiftHeld = event.modifierFlags.contains(.shift)

        switch transformHandle {
        case .translate:
            let dx = canvasPoint.x - start.x
            let dy = canvasPoint.y - start.y
            session.currentTransform = transformStartTransform
                .concatenating(CGAffineTransform(translationX: dx, y: dy))

        case .scaleTL, .scaleTR, .scaleBR, .scaleBL:
            // Scale around the opposite corner of the source-bounds rect
            // so it stays fixed in canvas space.
            let b = session.sourceBounds
            let anchorCanvas: CGPoint = {
                switch transformHandle {
                case .scaleTL: return CGPoint(x: b.maxX, y: b.minY) // opposite = BR
                case .scaleTR: return CGPoint(x: b.minX, y: b.minY) // opposite = BL
                case .scaleBR: return CGPoint(x: b.minX, y: b.maxY) // opposite = TL
                case .scaleBL: return CGPoint(x: b.maxX, y: b.maxY) // opposite = TR
                default: return CGPoint(x: b.midX, y: b.midY)
                }
            }()
            let anchorWorld = anchorCanvas.applying(transformStartTransform)
            let startVec = CGPoint(x: start.x - anchorWorld.x, y: start.y - anchorWorld.y)
            let currVec = CGPoint(x: canvasPoint.x - anchorWorld.x, y: canvasPoint.y - anchorWorld.y)
            // Signed scale factors (negative = flip)
            var sx = (abs(startVec.x) > 0.5) ? currVec.x / startVec.x : 1.0
            var sy = (abs(startVec.y) > 0.5) ? currVec.y / startVec.y : 1.0
            if shiftHeld {
                // Uniform scale — use the larger magnitude
                let s = abs(sx) >= abs(sy) ? sx : sy
                sx = s
                sy = s
            }
            // Compose: translate anchor to origin, scale, translate back, then apply start transform
            let scaleAroundAnchor = CGAffineTransform(translationX: -anchorWorld.x, y: -anchorWorld.y)
                .concatenating(CGAffineTransform(scaleX: sx, y: sy))
                .concatenating(CGAffineTransform(translationX: anchorWorld.x, y: anchorWorld.y))
            session.currentTransform = transformStartTransform.concatenating(scaleAroundAnchor)

        case .rotate:
            let centerWorld = CGPoint(x: session.sourceBounds.midX,
                                      y: session.sourceBounds.midY)
                .applying(transformStartTransform)
            let a1 = atan2(start.y - centerWorld.y, start.x - centerWorld.x)
            let a2 = atan2(canvasPoint.y - centerWorld.y, canvasPoint.x - centerWorld.x)
            var delta = a2 - a1
            if shiftHeld {
                // Snap to 15° increments
                let step = CGFloat.pi / 12
                delta = (delta / step).rounded() * step
            }
            let rotate = CGAffineTransform(translationX: -centerWorld.x, y: -centerWorld.y)
                .concatenating(CGAffineTransform(rotationAngle: delta))
                .concatenating(CGAffineTransform(translationX: centerWorld.x, y: centerWorld.y))
            session.currentTransform = transformStartTransform.concatenating(rotate)

        case .none:
            break
        }

        viewModel.objectWillChange.send()  // trigger redraw of overlay + composite
    }

    private func handleTransformMouseUp(_ event: NSEvent) {
        // Record the pre-drag state so Cmd+Z inside the session can roll it back.
        if transformHandle != .none,
           let session = viewModel?.transformSession,
           transformStartTransform != session.currentTransform {
            session.pushHistoryState(transformStartTransform)
        }
        transformHandle = .none
        transformDragStart = nil
    }

    /// Commit any pending transform back onto the layer.
    private func commitTransformIfNeeded() {
        guard let viewModel = viewModel, let renderer = renderer,
              let session = viewModel.transformSession else { return }
        session.commit(
            context: renderer.context,
            textureManager: renderer.textureManager,
            compositor: renderer.compositor
        )
        viewModel.transformSession = nil
        if let layer = viewModel.layerStack?.activeLayer {
            renderer.updateThumbnail(for: layer)
        }
    }

    // MARK: - Public undo/redo entry points (used by Edit menu + Cmd+Z)

    /// Session-aware undo: during a transform session, steps back through
    /// handle-drag history (cancelling the session on exhaustion). Otherwise
    /// performs a normal canvas undo.
    func performUndoAction() {
        guard let viewModel = viewModel, let renderer = renderer else { return }
        if let session = viewModel.transformSession {
            if session.undoLastDrag() {
                viewModel.objectWillChange.send()
                redrawOverlays()
            } else {
                cancelTransformIfNeeded()
            }
            return
        }
        viewModel.performUndo(renderer: renderer)
        redrawOverlays()
    }

    /// Session-aware redo.
    func performRedoAction() {
        guard let viewModel = viewModel, let renderer = renderer else { return }
        if let session = viewModel.transformSession {
            if session.redoLastDrag() {
                viewModel.objectWillChange.send()
                redrawOverlays()
            }
            return
        }
        viewModel.performRedo(renderer: renderer)
        redrawOverlays()
    }

    /// Select all pixels on the canvas. Pushes a proper undo snapshot so
    /// Cmd+Z reverts just the selection, not the previous action.
    func performSelectAllAction() {
        guard let viewModel = viewModel, let renderer = renderer else { return }
        // Any pending transform auto-commits via the tool-change observer; if a
        // session is somehow still active, flush it here too.
        if viewModel.transformSession != nil {
            commitTransformIfNeeded()
        }
        viewModel.saveUndoSnapshot(renderer: renderer, description: "Select All")
        viewModel.selectAll()
        redrawOverlays()
    }

    /// Clear the current selection. Pushes an undo snapshot.
    func performDeselectAction() {
        guard let viewModel = viewModel, let renderer = renderer else { return }
        guard viewModel.selectionPath != nil else { return }
        viewModel.saveUndoSnapshot(renderer: renderer, description: "Deselect")
        viewModel.clearSelection()
        redrawOverlays()
    }

    // MARK: - Cut / Copy / Paste

    /// Copy pixels from the active layer to the system pasteboard, cropped
    /// to the selection's bounding box if there is one. Async: returns
    /// immediately; pasteboard is updated when the background encode
    /// completes (~50–200 ms on a 2048² canvas).
    func performCopyAction() {
        guard let viewModel = viewModel, let renderer = renderer,
              let layer = viewModel.layerStack?.activeLayer else { return }
        if viewModel.transformSession != nil { commitTransformIfNeeded() }
        ClipboardManager.copyAsync(
            layer: layer,
            canvasSize: viewModel.canvasSize,
            selectionPath: viewModel.selectionPath,
            renderer: renderer
        )
    }

    /// Copy (async), then clear the source region. The clear runs
    /// synchronously on the GPU (fast) so the user sees the effect
    /// immediately; the pasteboard write completes in the background.
    func performCutAction() {
        guard let viewModel = viewModel, let renderer = renderer,
              let layer = viewModel.layerStack?.activeLayer else { return }
        if layer.isLocked { NSSound.beep(); return }
        if viewModel.transformSession != nil { commitTransformIfNeeded() }

        viewModel.saveUndoSnapshot(renderer: renderer, description: "Cut")

        ClipboardManager.copyAsync(
            layer: layer,
            canvasSize: viewModel.canvasSize,
            selectionPath: viewModel.selectionPath,
            renderer: renderer
        )

        if let path = viewModel.selectionPath {
            renderer.clearInsideSelection(path: path, layer: layer, context: renderer.context)
        } else {
            guard let cmdBuf = renderer.context.commandQueue.makeCommandBuffer() else { return }
            renderer.textureManager.clearTexture(layer.texture, commandBuffer: cmdBuf)
            cmdBuf.commit()
            // Don't wait — the next frame picks up the cleared texture.
        }
        renderer.updateThumbnail(for: layer)
    }

    /// Paste the pasteboard image as a new layer centered on the canvas.
    /// Synchronous main-thread work is minimal: undo snapshot + layer insert.
    /// All image decoding, U8↔F16 conversion, and texture upload happen on a
    /// background queue.
    func performPasteAction() {
        guard let viewModel = viewModel, let renderer = renderer,
              let layerStack = viewModel.layerStack else { return }

        // Cheap pasteboard-availability check (no decode).
        let pb = NSPasteboard.general
        let imageTypes: [NSPasteboard.PasteboardType] = [.png, .tiff, .fileURL]
        guard pb.availableType(from: imageTypes) != nil else { return }

        if viewModel.transformSession != nil { commitTransformIfNeeded() }

        viewModel.saveUndoSnapshot(renderer: renderer, description: "Paste")

        let W = Int(viewModel.canvasSize.width)
        let H = Int(viewModel.canvasSize.height)

        guard let texture = try? renderer.textureManager.makeCanvasTexture(
            width: W, height: H, label: "Pasted"
        ) else { return }

        let pasted = Layer(name: "Pasted", texture: texture)
        layerStack.layers.insert(pasted, at: layerStack.activeLayerIndex + 1)
        layerStack.activeLayerIndex += 1

        // Decode + rasterize + upload on background — no main-thread block.
        let context = renderer.context
        let canvasSize = viewModel.canvasSize
        DispatchQueue.global(qos: .userInitiated).async { [weak renderer, weak pasted] in
            guard let image = ClipboardManager.readImage() else { return }
            guard let cgImage = Self.pasteboardImageCenteredInCanvas(image, canvasSize: canvasSize) else { return }
            CanvasDocument.loadCGImageIntoTexture(
                cgImage: cgImage,
                texture: texture,
                context: context
            )
            DispatchQueue.main.async { [weak renderer, weak pasted] in
                guard let renderer = renderer, let pasted = pasted else { return }
                renderer.updateThumbnail(for: pasted)
            }
        }
    }

    /// Render an NSImage at its native size, centered on a canvas-sized
    /// RGBA8 CGImage. If the image is larger than the canvas, it's scaled
    /// down to fit while preserving aspect ratio.
    private static func pasteboardImageCenteredInCanvas(_ image: NSImage, canvasSize: CGSize) -> CGImage? {
        let W = Int(canvasSize.width), H = Int(canvasSize.height)
        guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = CGContext(
                data: nil, width: W, height: H,
                bitsPerComponent: 8, bytesPerRow: W * 4,
                space: colorSpace,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              ) else { return nil }

        // Derive a CGImage from the NSImage.
        var imgRect = CGRect(x: 0, y: 0, width: image.size.width, height: image.size.height)
        guard let srcCG = image.cgImage(forProposedRect: &imgRect, context: nil, hints: nil) else {
            return nil
        }

        // Fit-to-canvas preserving aspect ratio (downscale only).
        let srcAspect = imgRect.width / imgRect.height
        let dstAspect = CGFloat(W) / CGFloat(H)
        var drawW = imgRect.width
        var drawH = imgRect.height
        if drawW > CGFloat(W) || drawH > CGFloat(H) {
            if srcAspect > dstAspect {
                drawW = CGFloat(W)
                drawH = drawW / srcAspect
            } else {
                drawH = CGFloat(H)
                drawW = drawH * srcAspect
            }
        }
        let drawX = (CGFloat(W) - drawW) / 2
        let drawY = (CGFloat(H) - drawH) / 2
        ctx.draw(srcCG, in: CGRect(x: drawX, y: drawY, width: drawW, height: drawH))
        return ctx.makeImage()
    }

    /// Ask every sibling overlay view (selection marquee, transform handles) to
    /// redraw immediately, instead of waiting for their internal animation timer.
    private func redrawOverlays() {
        superview?.subviews.forEach { $0.needsDisplay = true }
    }

    /// Abort any pending transform, restoring the original layer state and
    /// popping the speculative "Transform" undo snapshot that was pushed when
    /// the session began (there's nothing for undo to revert to now).
    private func cancelTransformIfNeeded() {
        guard let viewModel = viewModel, let renderer = renderer,
              let session = viewModel.transformSession else { return }
        session.cancel(
            context: renderer.context,
            textureManager: renderer.textureManager,
            compositor: renderer.compositor
        )
        viewModel.transformSession = nil
        viewModel.undoManager.popLastSnapshot()
        if let layer = viewModel.layerStack?.activeLayer {
            renderer.updateThumbnail(for: layer)
        }
    }

    /// Return which handle (if any) the canvas-space point hits. Tolerance is
    /// view-space pixels converted to canvas-space via the current zoom.
    private func hitTestTransformHandle(at canvasPoint: CGPoint, session: TransformSession) -> TransformHandle {
        let scale = viewModel.transform.scale
        let hitRadiusView: CGFloat = 10          // view-space radius in pixels
        let hitRadius = hitRadiusView / scale    // canvas-space radius

        let corners = session.transformedCorners  // TL, TR, BR, BL
        if distance(canvasPoint, corners[0]) < hitRadius { return .scaleTL }
        if distance(canvasPoint, corners[1]) < hitRadius { return .scaleTR }
        if distance(canvasPoint, corners[2]) < hitRadius { return .scaleBR }
        if distance(canvasPoint, corners[3]) < hitRadius { return .scaleBL }

        // Rotation handle — 28 view-px above the top-center along the rect's up direction
        let topCenter = CGPoint(
            x: (corners[0].x + corners[1].x) / 2,
            y: (corners[0].y + corners[1].y) / 2
        )
        let center = session.transformedCenter
        let dx = topCenter.x - center.x
        let dy = topCenter.y - center.y
        let len = max(sqrt(dx * dx + dy * dy), 0.001)
        let extend: CGFloat = 28 / max(0.001, scale)
        let rotHandle = CGPoint(
            x: topCenter.x + (dx / len) * extend,
            y: topCenter.y + (dy / len) * extend
        )
        if distance(canvasPoint, rotHandle) < hitRadius { return .rotate }

        // Inside the transformed rect → translate
        let path = CGMutablePath()
        path.move(to: corners[0])
        path.addLine(to: corners[1])
        path.addLine(to: corners[2])
        path.addLine(to: corners[3])
        path.closeSubpath()
        if path.contains(canvasPoint) { return .translate }

        return .none
    }

    private func distance(_ a: CGPoint, _ b: CGPoint) -> CGFloat {
        let dx = a.x - b.x
        let dy = a.y - b.y
        return sqrt(dx * dx + dy * dy)
    }

    // MARK: - Fill Tool

    private func handleFillMouseDown(_ event: NSEvent) {
        guard let viewModel = viewModel, let renderer = renderer,
              let layer = viewModel.layerStack?.activeLayer else { return }

        if layer.isLocked {
            NSSound.beep()
            return
        }

        let viewPoint = convert(event.locationInWindow, from: nil)
        let canvasPoint = viewModel.transform.viewToCanvas(viewPoint, viewSize: bounds.size)

        let cs = viewModel.canvasSize
        guard canvasPoint.x >= 0, canvasPoint.x < cs.width,
              canvasPoint.y >= 0, canvasPoint.y < cs.height else { return }

        // Snapshot BEFORE dispatching async work so redo/undo captures pre-fill state.
        viewModel.saveUndoSnapshot(renderer: renderer, description: "Fill")

        // Run fill in the background — returns immediately so the UI stays responsive.
        BucketFill.fillAsync(
            renderer: renderer,
            layer: layer,
            canvasPoint: canvasPoint,
            canvasSize: cs,
            fillColor: viewModel.currentColor,
            tolerance: viewModel.fillTolerance,
            selectionPath: viewModel.selectionPath
        ) { [weak renderer, weak layer] in
            guard let renderer = renderer, let layer = layer else { return }
            renderer.updateThumbnail(for: layer)
            // MTKView redraws continuously
        }
    }

    // MARK: - Selection Helpers

    private func updateSelectionDrag(to canvasPoint: CGPoint) {
        guard let anchor = selectionAnchor, let viewModel = viewModel else { return }

        switch viewModel.selectionMode {
        case .rectangle:
            let rect = CGRect(
                x: min(anchor.x, canvasPoint.x),
                y: min(anchor.y, canvasPoint.y),
                width: abs(canvasPoint.x - anchor.x),
                height: abs(canvasPoint.y - anchor.y)
            )
            viewModel.selectionPath = CGPath(rect: rect, transform: nil)

        case .ellipse:
            let rect = CGRect(
                x: min(anchor.x, canvasPoint.x),
                y: min(anchor.y, canvasPoint.y),
                width: abs(canvasPoint.x - anchor.x),
                height: abs(canvasPoint.y - anchor.y)
            )
            viewModel.selectionPath = CGPath(ellipseIn: rect, transform: nil)

        case .freeform:
            selectionDragPoints.append(canvasPoint)
            let mutablePath = CGMutablePath()
            mutablePath.addLines(between: selectionDragPoints)
            viewModel.selectionPath = mutablePath.copy()
        }
    }

    private func finalizeSelection() {
        guard let viewModel = viewModel else { return }

        if viewModel.selectionMode == .freeform, selectionDragPoints.count > 2 {
            let mutablePath = CGMutablePath()
            mutablePath.addLines(between: selectionDragPoints)
            mutablePath.closeSubpath()
            viewModel.selectionPath = mutablePath.copy()
        }
        selectionAnchor = nil
        selectionDragPoints = []
    }

    // MARK: - Shape Helpers

    private func updateShapePreview(to canvasPoint: CGPoint) {
        guard let viewModel = viewModel else { return }

        switch viewModel.currentShape {
        case .rectangle:
            guard let anchor = shapeAnchor else { return }
            let rect = CGRect(
                x: min(anchor.x, canvasPoint.x),
                y: min(anchor.y, canvasPoint.y),
                width: abs(canvasPoint.x - anchor.x),
                height: abs(canvasPoint.y - anchor.y)
            )
            viewModel.previewShapePath = CGPath(rect: rect, transform: nil)

        case .ellipse:
            guard let anchor = shapeAnchor else { return }
            let rect = CGRect(
                x: min(anchor.x, canvasPoint.x),
                y: min(anchor.y, canvasPoint.y),
                width: abs(canvasPoint.x - anchor.x),
                height: abs(canvasPoint.y - anchor.y)
            )
            viewModel.previewShapePath = CGPath(ellipseIn: rect, transform: nil)

        case .freeform:
            shapeFreeformPoints.append(canvasPoint)
            let mutablePath = CGMutablePath()
            mutablePath.addLines(between: shapeFreeformPoints)
            viewModel.previewShapePath = mutablePath.copy()
        }
    }

    private func commitShape() {
        guard let viewModel = viewModel, let renderer = renderer else { return }
        guard let activeLayer = viewModel.layerStack?.activeLayer else {
            shapeAnchor = nil
            shapeFreeformPoints = []
            viewModel.previewShapePath = nil
            return
        }

        // Close freeform path before committing
        var finalPath = viewModel.previewShapePath
        if viewModel.currentShape == .freeform, shapeFreeformPoints.count > 2 {
            let mutablePath = CGMutablePath()
            mutablePath.addLines(between: shapeFreeformPoints)
            mutablePath.closeSubpath()
            finalPath = mutablePath.copy()
        }

        // Clear preview immediately so the final rasterized shape replaces it visually
        shapeAnchor = nil
        shapeFreeformPoints = []
        viewModel.previewShapePath = nil

        if let path = finalPath {
            viewModel.saveUndoSnapshot(renderer: renderer, description: "Shape")

            renderer.drawShape(
                path: path,
                strokeColor: viewModel.shapeStrokeEnabled ? viewModel.currentColor : nil,
                fillColor: viewModel.shapeFillEnabled ? viewModel.swapBackgroundColor : nil,
                strokeWidth: viewModel.shapeStrokeWidth,
                layer: activeLayer,
                context: renderer.context
            )
            // Thumbnail update is async so it doesn't block cmd+z
            DispatchQueue.global(qos: .userInitiated).async { [weak renderer, weak activeLayer] in
                guard let renderer = renderer, let activeLayer = activeLayer else { return }
                renderer.updateThumbnail(for: activeLayer)
            }
        }
    }

    // MARK: - Mouse Moved (cursor feedback)

    override func mouseMoved(with event: NSEvent) {
        guard let viewModel = viewModel else { return }

        if viewModel.currentTool == .selection, let path = viewModel.selectionPath {
            let viewPoint = convert(event.locationInWindow, from: nil)
            let canvasPoint = viewModel.transform.viewToCanvas(viewPoint, viewSize: bounds.size)
            if path.contains(canvasPoint) {
                NSCursor.openHand.set()
            } else {
                NSCursor.crosshair.set()
            }
        }
    }

    // MARK: - Move Content

    private func handleMoveDrag(to canvasPoint: CGPoint) {
        guard let viewModel = viewModel,
              let lastPoint = moveLastCanvasPoint else { return }

        let dx = canvasPoint.x - lastPoint.x
        let dy = canvasPoint.y - lastPoint.y
        guard abs(dx) > 0.5 || abs(dy) > 0.5 else { return }

        moveLastCanvasPoint = canvasPoint

        // Update the floating content offset
        selectionMoveHandler.updateOffset(dx: dx, dy: dy)
        viewModel.floatingOffset = selectionMoveHandler.floatingOffset

        // Shift the selection path to follow
        if let path = viewModel.selectionPath {
            var transform = CGAffineTransform(translationX: dx, y: dy)
            if let shifted = path.copy(using: &transform) {
                viewModel.selectionPath = shifted
            }
        }
    }

    // MARK: - Tablet Events

    override func tabletPoint(with event: NSEvent) {}

    override func tabletProximity(with event: NSEvent) {
        // Handled by app-level event monitor
    }

    // MARK: - Scroll / Zoom

    override func scrollWheel(with event: NSEvent) {
        guard let viewModel = viewModel else { return }

        if event.modifierFlags.contains(.command) {
            let zoomFactor: CGFloat = event.scrollingDeltaY > 0 ? 1.1 : 0.9
            let location = convert(event.locationInWindow, from: nil)
            viewModel.transform.zoom(by: zoomFactor, at: location, viewSize: bounds.size)
        } else {
            viewModel.transform.pan(by: CGPoint(
                x: event.scrollingDeltaX,
                y: event.scrollingDeltaY
            ))
        }
    }

    override func magnify(with event: NSEvent) {
        guard let viewModel = viewModel else { return }
        let location = convert(event.locationInWindow, from: nil)
        viewModel.transform.zoom(by: 1.0 + event.magnification, at: location, viewSize: bounds.size)
    }

    // MARK: - Keyboard

    override func keyDown(with event: NSEvent) {
        guard let viewModel = viewModel else {
            super.keyDown(with: event)
            return
        }

        // Cmd modifier shortcuts
        if event.modifierFlags.contains(.command) {
            switch event.charactersIgnoringModifiers {
            case "f":
                if viewModel.isDistractionFree {
                    NotificationCenter.default.post(name: .exitDistractionFree, object: nil)
                } else {
                    NotificationCenter.default.post(name: .enterDistractionFree, object: nil)
                }
                return
            case "z":
                // The Edit menu binds Cmd+Z too and normally intercepts this before
                // keyDown. Keeping a fallback here in case the responder chain
                // ever lets it through.
                if event.modifierFlags.contains(.shift) {
                    performRedoAction()
                } else {
                    performUndoAction()
                }
            case "a":
                viewModel.saveUndoSnapshot(renderer: renderer, description: "Select All")
                viewModel.selectAll()
            case "d":
                viewModel.saveUndoSnapshot(renderer: renderer, description: "Deselect")
                viewModel.clearSelection()
            case "0":
                viewModel.transform.zoomToFit(canvasSize: viewModel.canvasSize, viewSize: bounds.size)
            case "1":
                viewModel.transform.scale = 1.0
                viewModel.transform.offset = .zero
            case "=", "+":
                let center = CGPoint(x: bounds.midX, y: bounds.midY)
                viewModel.transform.zoom(by: 1.5, at: center, viewSize: bounds.size)
            case "-":
                let center = CGPoint(x: bounds.midX, y: bounds.midY)
                viewModel.transform.zoom(by: 0.667, at: center, viewSize: bounds.size)
            default:
                super.keyDown(with: event)
            }
            return
        }

        // Tab key — toggle right panel
        if event.keyCode == 48 {
            viewModel.toggleRightPanel()
            return
        }

        // Transform tool: Return commits, Escape cancels
        if viewModel.transformSession != nil {
            if event.keyCode == 36 || event.keyCode == 76 { // Return / Enter
                commitTransformIfNeeded()
                return
            }
            if event.keyCode == 53 { // Escape
                cancelTransformIfNeeded()
                return
            }
        }

        // Delete/Backspace key — clear inside selection
        if event.keyCode == 51 || event.keyCode == 117 {
            if let path = viewModel.selectionPath,
               let activeLayer = viewModel.layerStack?.activeLayer {
                viewModel.saveUndoSnapshot(renderer: renderer, description: "Delete Selection")
                renderer.clearInsideSelection(path: path, layer: activeLayer, context: renderer.context)
                renderer.updateThumbnail(for: activeLayer)
            }
            return
        }

        switch event.charactersIgnoringModifiers {
        case " ":
            isSpaceHeld = true
            NSCursor.openHand.set()
        case "b", "B":
            viewModel.currentTool = .brush
            viewModel.currentBrush = .hardRound
        case "e", "E":
            viewModel.currentTool = .eraser
            viewModel.currentBrush = .eraser
        case "h", "H":
            viewModel.currentTool = .pan
            NSCursor.openHand.set()
        case "s", "S":
            viewModel.currentTool = .selection
        case "u", "U":
            viewModel.currentTool = .shape
        case "i", "I":
            viewModel.currentTool = .eyedropper
        case "g", "G":
            viewModel.currentTool = .fill
        case "t", "T":
            viewModel.currentTool = .transform
        case "[":
            viewModel.brushSize = max(1, viewModel.brushSize - 2)
        case "]":
            viewModel.brushSize = min(500, viewModel.brushSize + 2)
        case "{":
            viewModel.brushOpacity = max(0.05, viewModel.brushOpacity - 0.05)
        case "}":
            viewModel.brushOpacity = min(1.0, viewModel.brushOpacity + 0.05)
        case "d", "D":
            viewModel.resetColors()
        case "x", "X":
            viewModel.swapColors()
        case "1":
            viewModel.currentTool = .brush
            viewModel.currentBrush = .hardRound
        case "2":
            viewModel.currentTool = .brush
            viewModel.currentBrush = .softRound
        case "3":
            viewModel.currentTool = .brush
            viewModel.currentBrush = .pencil
        case "4":
            viewModel.currentTool = .brush
            viewModel.currentBrush = .inkBrush
        case "5":
            viewModel.currentTool = .brush
            viewModel.currentBrush = .marker
        default:
            super.keyDown(with: event)
        }
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if event.keyCode == 53, let viewModel = viewModel, viewModel.isDistractionFree {
            NotificationCenter.default.post(name: .exitDistractionFree, object: nil)
            return true
        }
        return super.performKeyEquivalent(with: event)
    }

    override func keyUp(with event: NSEvent) {
        if event.charactersIgnoringModifiers == " " {
            isSpaceHeld = false
            NSCursor.arrow.set()
        }
    }

    override func flagsChanged(with event: NSEvent) {}

    // Cmd+A Select All via responder chain
    @objc override func selectAll(_ sender: Any?) {
        viewModel?.selectAll()
    }

    // MARK: - Helpers

    private func viewToCanvasPoint(_ point: StrokePoint) -> StrokePoint {
        let canvasPos = viewModel.transform.viewToCanvas(point.position, viewSize: bounds.size)
        return StrokePoint(
            position: canvasPos,
            pressure: point.pressure,
            tiltX: point.tiltX,
            tiltY: point.tiltY,
            rotation: point.rotation,
            timestamp: point.timestamp
        )
    }

    // MARK: - View Lifecycle

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        window?.makeFirstResponder(self)
        window?.acceptsMouseMovedEvents = true

        NotificationCenter.default.addObserver(
            self, selector: #selector(handleProximityChanged),
            name: .tabletProximityChanged, object: nil
        )
    }

    @objc private func handleProximityChanged() {
        guard let viewModel = viewModel else { return }

        if TabletEventHandler.isEraserActive {
            if previousBrush == nil {
                previousBrush = viewModel.currentBrush
            }
            viewModel.currentBrush = .eraser
            viewModel.currentTool = .eraser
        } else {
            if let prev = previousBrush {
                viewModel.currentBrush = prev
                viewModel.currentTool = .brush
                previousBrush = nil
            }
        }
    }
}
