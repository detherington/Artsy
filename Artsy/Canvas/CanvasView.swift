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
    private var brushCursorObservation: AnyCancellable?

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
        //   • always: swap the cursor to match the new tool — both via
        //     immediate .set() (works if cursor is already over canvas) AND
        //     invalidateCursorRects() so macOS re-queries when the mouse
        //     enters from outside the canvas (e.g. after clicking a sidebar
        //     button).
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
                self.cursor(for: newTool).set()
                self.window?.invalidateCursorRects(for: self)
            }

        // The brush cursor is a ring the size of the tip on screen, so it follows the
        // brush size and the zoom level.
        brushCursorObservation = viewModel.$brushSize.map { _ in () }
            .merge(with: viewModel.$transform.map(\.scale).removeDuplicates().map { _ in () })
            .receive(on: RunLoop.main)   // read the new values, not the ones being replaced
            .sink { [weak self] in
                guard let self = self, let window = self.window else { return }
                window.invalidateCursorRects(for: self)
                let tool = self.viewModel.currentTool
                if (tool == .brush || tool == .eraser), !self.isPanning, !self.isSpaceHeld,
                   self.bounds.contains(self.convert(window.mouseLocationOutsideOfEventStream, from: nil)) {
                    self.cursor(for: tool).set()
                }
            }
    }

    /// The cursor to show over the canvas for a tool.
    private func cursor(for tool: ToolType) -> NSCursor {
        guard tool == .brush || tool == .eraser, let viewModel = viewModel else {
            return ToolCursor.current(for: tool)
        }
        return BrushCursor.cursor(diameter: CGFloat(viewModel.brushSize) * viewModel.transform.scale)
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

        // ⌘-drag picks up a guide line
        if event.modifierFlags.contains(.command) {
            let viewPoint = convert(event.locationInWindow, from: nil)
            let canvasPoint = viewModel.transform.viewToCanvas(viewPoint, viewSize: bounds.size)
            if let line = viewModel.guides.line(near: canvasPoint, zoom: viewModel.transform.scale) {
                draggingGuide = line
                return
            }
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
                if viewModel.layerStack?.activeLayer?.isLocked == true { NSSound.beep(); return }
                isMovingSelection = true
                moveLastCanvasPoint = canvasPoint
                viewModel.saveUndoSnapshot(renderer: renderer, description: "Move Selection", changing: .layer(viewModel.layerStack?.activeLayer))

                if let activeLayer = viewModel.layerStack?.activeLayer {
                    selectionMoveHandler.begin(
                        selectionPath: path,
                        layer: activeLayer,
                        context: renderer.context,
                        textureManager: renderer.textureManager
                    )
                    viewModel.floatingTexture = selectionMoveHandler.floatingTexture
                    viewModel.floatingHeight = selectionMoveHandler.floatingHeight
                    viewModel.floatingOffset = .zero
                }
                NSCursor.closedHand.set()
                return
            }

            // Otherwise, start a new selection — save undo so the selection itself can be undone
            viewModel.saveUndoSnapshot(renderer: renderer, description: "Select", changing: .nothing)
            selectionAnchor = canvasPoint
            selectionDragPoints = [canvasPoint]
            viewModel.clearSelection()

        case .brush, .eraser:
            handleDrawingMouseDown(event)

        case .shape:
            if viewModel.layerStack?.activeLayer?.isLocked == true { NSSound.beep(); return }
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

        if let line = draggingGuide {
            let viewPoint = convert(event.locationInWindow, from: nil)
            viewModel.guides.move(line, to: viewModel.transform.viewToCanvas(viewPoint, viewSize: bounds.size))
            redrawOverlays()
            return
        }

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

        // A guide dragged off the canvas is gone
        if let line = draggingGuide {
            draggingGuide = nil
            let viewPoint = convert(event.locationInWindow, from: nil)
            let canvasPoint = viewModel.transform.viewToCanvas(viewPoint, viewSize: bounds.size)
            if !CGRect(origin: .zero, size: viewModel.canvasSize).contains(canvasPoint) {
                viewModel.guides.remove(line)
            } else {
                viewModel.guides.move(line, to: canvasPoint)
            }
            redrawOverlays()
            return
        }

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
                viewModel.noteContentChanged()
                renderer.updateThumbnail(for: activeLayer)
            }
            viewModel.floatingTexture = nil
            viewModel.floatingHeight = nil
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

        // A tablet reports several times per display frame. AppKit merges those reports by
        // default; while drawing we want every one.
        NSEvent.isMouseCoalescingEnabled = false

        renderer.beginStroke()
        viewModel.beginStroke(point: canvasPoint, hasPressure: TabletEventHandler.isTabletEvent(event))
    }

    private func handleDrawingMouseDragged(_ event: NSEvent) {
        guard let viewModel = viewModel else { return }

        let point = TabletEventHandler.strokePoint(from: event, in: self)
        let canvasPoint = viewToCanvasPoint(point)
        viewModel.continueStroke(point: canvasPoint)
    }

    private func handleDrawingMouseUp(_ event: NSEvent) {
        guard let viewModel = viewModel, let renderer = renderer else { return }

        // Finalize first: the renderer still needs the stroke's points to draw its last samples.
        renderer.finalizeStroke()
        viewModel.endStroke()
        NSEvent.isMouseCoalescingEnabled = true
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

        // The composite is premultiplied; pick the colour as displayed, i.e. over the white
        // that shows through wherever the canvas isn't fully opaque.
        let through = 1 - Float(Float16(bitPattern: f16[3]))
        let r = Float(Float16(bitPattern: f16[0])) + through
        let g = Float(Float16(bitPattern: f16[1])) + through
        let b = Float(Float16(bitPattern: f16[2])) + through
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

    /// The undo step the transform session saved when it began, which a cancel takes back.
    private var transformStepToken: Int?

    /// Finish whatever a tool is in the middle of, so the layers hold everything the canvas
    /// shows: before a save, an export, or a change to the layer list.
    func commitPendingEdits() {
        commitTransformIfNeeded()
    }

    /// Ensure a TransformSession exists for the active layer. Starts one if
    /// missing. If a selection is active, only its pixels get transformed;
    /// otherwise the whole layer is transformed.
    private func ensureTransformSession() {
        guard let viewModel = viewModel, let renderer = renderer else { return }
        if viewModel.transformSession != nil { return }
        guard let layer = viewModel.layerStack?.activeLayer else { return }
        if layer.isLocked { NSSound.beep(); return }

        let selectionPath = viewModel.selectionPath
        viewModel.saveUndoSnapshot(renderer: renderer, description: "Transform", changing: .layer(layer))
        transformStepToken = viewModel.undoManager.lastStepToken

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

        // Closed hand while actively dragging to translate; other handles keep
        // their hover cursor throughout the drag.
        TransformCursor.current(for: transformHandle, dragging: true).set()
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

        // Go back to the hover cursor under the mouse.
        let viewPoint = convert(event.locationInWindow, from: nil)
        if let viewModel = viewModel, let session = viewModel.transformSession {
            let canvasPoint = viewModel.transform.viewToCanvas(viewPoint, viewSize: bounds.size)
            let handle = hitTestTransformHandle(at: canvasPoint, session: session)
            TransformCursor.current(for: handle, dragging: false).set()
        }
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
        viewModel.noteContentChanged()
        viewModel.transformSession = nil
        transformStepToken = nil
        if let layer = viewModel.layerStack?.activeLayer {
            renderer.updateThumbnail(for: layer)
        }
    }

    // MARK: - Public undo/redo entry points (used by Edit menu + Cmd+Z)

    /// Session-aware undo: during a transform session, steps back through
    /// handle-drag history (cancelling the session on exhaustion). Otherwise
    /// performs a normal canvas undo.
    func performUndoAction() {
        guard let viewModel = viewModel, let renderer = renderer, !viewModel.isDrawing else { return }
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
        guard let viewModel = viewModel, let renderer = renderer, !viewModel.isDrawing else { return }
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
        viewModel.saveUndoSnapshot(renderer: renderer, description: "Select All", changing: .nothing)
        viewModel.selectAll()
        redrawOverlays()
    }

    /// Clear the current selection. Pushes an undo snapshot.
    func performDeselectAction() {
        guard let viewModel = viewModel, let renderer = renderer else { return }
        guard viewModel.selectionPath != nil else { return }
        viewModel.saveUndoSnapshot(renderer: renderer, description: "Deselect", changing: .nothing)
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

        viewModel.saveUndoSnapshot(renderer: renderer, description: "Cut", changing: .layer(layer))

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
            if let height = layer.heightTexture {
                renderer.textureManager.clearTexture(height, commandBuffer: cmdBuf)
            }
            cmdBuf.commit()
            // Don't wait — the next frame picks up the cleared texture.
        }
        renderer.updateThumbnail(for: layer)
    }

    /// Paste at the exact canvas-space origin where the content was copied
    /// from (if the pasteboard has Artsy's private origin metadata).
    /// Falls back to centered paste for content from other apps.
    func performPasteInPlaceAction() {
        performPaste(inPlace: true)
    }

    /// Paste the pasteboard image as a new layer centered on the canvas.
    /// Synchronous main-thread work is minimal: undo snapshot + layer insert.
    /// All image decoding, U8↔F16 conversion, and texture upload happen on a
    /// background queue.
    func performPasteAction() {
        performPaste(inPlace: false)
    }

    /// Shared paste implementation. When `inPlace` is true, positions the
    /// pasted image at the origin stored on the pasteboard (or centers if
    /// none). When false, always centers.
    private func performPaste(inPlace: Bool) {
        guard let viewModel = viewModel, let renderer = renderer,
              let layerStack = viewModel.layerStack else { return }

        // Cheap pasteboard-availability check (no decode).
        let pb = NSPasteboard.general
        let imageTypes: [NSPasteboard.PasteboardType] = [.png, .tiff, .fileURL]
        guard pb.availableType(from: imageTypes) != nil else { return }

        if viewModel.transformSession != nil { commitTransformIfNeeded() }

        // Paste in place uses the origin stored on the pasteboard by a prior
        // Artsy copy. For content from other apps (or whole-layer copies at
        // origin (0,0)), falls back to centered placement.
        let origin: CGPoint? = inPlace ? ClipboardManager.readOrigin() : nil

        guard layerStack.layers.count < layerStack.layerLimit else { NSSound.beep(); return }

        let W = Int(viewModel.canvasSize.width)
        let H = Int(viewModel.canvasSize.height)

        guard let texture = try? renderer.textureManager.makeCanvasTexture(
            width: W, height: H, label: "Pasted"
        ), let clear = renderer.context.commandQueue.makeCommandBuffer() else { return }
        // The upload writes only the image's rectangle; the rest must be empty
        renderer.textureManager.clearTexture(texture, commandBuffer: clear)
        clear.commit()

        // Pasting adds a layer; nothing already there changes
        viewModel.saveUndoSnapshot(
            renderer: renderer,
            description: inPlace ? "Paste in Place" : "Paste",
            changing: .nothing
        )
        let pasteStep = viewModel.undoManager.lastStepToken

        let pasted = Layer(name: "Pasted", texture: texture)
        layerStack.layers.insert(pasted, at: layerStack.activeLayerIndex + 1)
        layerStack.activeLayerIndex += 1

        let context = renderer.context
        let canvasSize = viewModel.canvasSize
        let textureManager = renderer.textureManager
        DispatchQueue.global(qos: .userInitiated).async { [weak renderer, weak pasted, weak viewModel] in
            guard let image = ClipboardManager.readImage() else {
                // Nothing to paste after all: take the empty layer and its step back
                DispatchQueue.main.async { [weak viewModel, weak pasted] in
                    guard let viewModel, let layerStack = viewModel.layerStack, let pasted,
                          let index = layerStack.layers.firstIndex(where: { $0 === pasted }) else { return }
                    layerStack.removeLayer(at: index)
                    layerStack.activeLayerIndex = max(0, min(index - 1, layerStack.layers.count - 1))
                    viewModel.undoManager.popLastSnapshot(if: pasteStep)
                }
                return
            }
            Self.uploadPastedImage(
                image,
                origin: origin,
                canvasSize: canvasSize,
                texture: texture,
                context: context,
                textureManager: textureManager
            )
            DispatchQueue.main.async { [weak renderer, weak pasted] in
                guard let renderer = renderer, let pasted = pasted else { return }
                renderer.updateThumbnail(for: pasted)
                renderer.viewModel?.noteContentChanged()
            }
        }
    }

    /// Fast paste upload — converts and writes ONLY the image's pixel area
    /// into the correct subregion of the canvas-sized target texture, not
    /// the whole canvas. For a 200×200 paste on a 2048² canvas that's
    /// ~100× less work than the old full-canvas intermediate.
    ///
    /// - origin: canvas-space Y-up position of the image's bottom-left.
    ///           nil means "center on canvas."
    private static func uploadPastedImage(
        _ image: NSImage,
        origin: CGPoint?,
        canvasSize: CGSize,
        texture: MTLTexture,
        context: MetalContext,
        textureManager: TextureManager
    ) {
        var imgRect = CGRect(x: 0, y: 0, width: image.size.width, height: image.size.height)
        guard let srcCG = image.cgImage(forProposedRect: &imgRect, context: nil, hints: nil) else {
            return
        }

        let canvasW = CGFloat(canvasSize.width)
        let canvasH = CGFloat(canvasSize.height)

        // Scale image to fit canvas if it's larger (preserve aspect ratio).
        var drawW = imgRect.width
        var drawH = imgRect.height
        if drawW > canvasW || drawH > canvasH {
            let srcAspect = drawW / drawH
            let dstAspect = canvasW / canvasH
            if srcAspect > dstAspect {
                drawW = canvasW
                drawH = drawW / srcAspect
            } else {
                drawH = canvasH
                drawW = drawH * srcAspect
            }
        }

        let placementOrigin: CGPoint
        if let origin = origin {
            placementOrigin = origin
        } else {
            placementOrigin = CGPoint(
                x: (canvasW - drawW) / 2,
                y: (canvasH - drawH) / 2
            )
        }

        let regionW = Int(drawW.rounded())
        let regionH = Int(drawH.rounded())
        guard regionW > 0, regionH > 0 else { return }

        // Canvas Y-up → texture Y-down
        let texX = Int(placementOrigin.x.rounded())
        let texY = Int((canvasH - placementOrigin.y - drawH).rounded())
        // Clip region to texture bounds
        let clippedX = max(0, texX)
        let clippedY = max(0, texY)
        let clippedW = min(regionW, texture.width - clippedX)
        let clippedH = min(regionH, texture.height - clippedY)
        guard clippedW > 0, clippedH > 0 else { return }

        // 1. Draw the image into a region-sized RGBA8 context, in the canvas's colour space
        //    (an image from another app is converted into it here).
        guard let colorSpace = CGColorSpace(name: CGColorSpace.displayP3),
              let ctx = CGContext(
                data: nil, width: regionW, height: regionH,
                bitsPerComponent: 8, bytesPerRow: regionW * 4,
                space: colorSpace,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              ) else { return }
        ctx.draw(srcCG, in: CGRect(x: 0, y: 0, width: regionW, height: regionH))
        guard let dataPtr = ctx.data else { return }
        let rgba8 = dataPtr.assumingMemoryBound(to: UInt8.self)

        // 2. Convert region to F16 via LUT (unsafe pointer loop).
        let pixelCount = regionW * regionH
        var f16 = [UInt16](repeating: 0, count: pixelCount * 4)
        let lut = CanvasDocument.u8ToF16LUTPublic
        f16.withUnsafeMutableBufferPointer { dst in
            let dstPtr = dst.baseAddress!
            let total = pixelCount * 4
            var i = 0
            while i < total {
                dstPtr[i]     = lut[Int(rgba8[i])]
                dstPtr[i + 1] = lut[Int(rgba8[i + 1])]
                dstPtr[i + 2] = lut[Int(rgba8[i + 2])]
                dstPtr[i + 3] = lut[Int(rgba8[i + 3])]
                i += 4
            }
        }

        // 3. Upload to a region-sized shared texture, then blit into the
        //    target canvas texture at the correct offset.
        guard let staging = try? textureManager.makeSharedTexture(
            width: regionW, height: regionH, label: "PasteStaging"
        ) else { return }

        f16.withUnsafeBytes { raw in
            staging.replace(
                region: MTLRegion(
                    origin: MTLOrigin(x: 0, y: 0, z: 0),
                    size: MTLSize(width: regionW, height: regionH, depth: 1)
                ),
                mipmapLevel: 0,
                withBytes: raw.baseAddress!,
                bytesPerRow: regionW * 8
            )
        }

        guard let cmdBuf = context.commandQueue.makeCommandBuffer(),
              let blit = cmdBuf.makeBlitCommandEncoder() else { return }
        blit.copy(
            from: staging,
            sourceSlice: 0, sourceLevel: 0,
            sourceOrigin: MTLOrigin(x: max(0, clippedX - texX), y: max(0, clippedY - texY), z: 0),
            sourceSize: MTLSize(width: clippedW, height: clippedH, depth: 1),
            to: texture,
            destinationSlice: 0, destinationLevel: 0,
            destinationOrigin: MTLOrigin(x: clippedX, y: clippedY, z: 0)
        )
        blit.endEncoding()
        cmdBuf.commit()
    }

    /// Ask every sibling overlay view (selection marquee, transform handles) to
    /// redraw immediately, instead of waiting for their internal animation timer.
    /// The guide line being ⌘-dragged, if any.
    private var draggingGuide: CanvasGuides.Line?

    func redrawOverlays() {
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
        // Only the step the session itself saved; anything saved since stays
        viewModel.undoManager.popLastSnapshot(if: transformStepToken)
        transformStepToken = nil
        viewModel.noteContentChanged()
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
        viewModel.saveUndoSnapshot(renderer: renderer, description: "Fill", changing: .layer(viewModel.layerStack?.activeLayer))
        let fillStep = viewModel.undoManager.lastStepToken

        // Run fill in the background — returns immediately so the UI stays responsive.
        BucketFill.fillAsync(
            renderer: renderer,
            layer: layer,
            canvasPoint: canvasPoint,
            canvasSize: cs,
            fillColor: viewModel.currentColor,
            tolerance: viewModel.fillTolerance,
            selectionPath: viewModel.selectionPath,
            shouldApply: { [weak viewModel, weak layer] in
                // Not if the fill was undone before it finished, or its layer is gone
                guard let viewModel, let layer, viewModel.undoManager.holds(fillStep),
                      viewModel.layerStack?.layers.contains(where: { $0 === layer }) == true else { return false }
                return true
            }
        ) { [weak renderer, weak layer] in
            guard let renderer = renderer, let layer = layer else { return }
            renderer.updateThumbnail(for: layer)
            // The pixels changed after the undo step noted them: tell the display
            renderer.viewModel?.noteContentChanged()
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
            viewModel.saveUndoSnapshot(renderer: renderer, description: "Shape", changing: .layer(viewModel.layerStack?.activeLayer))

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

    // MARK: - Cursor registration

    /// Register the current tool's cursor for the entire canvas view so the
    /// correct cursor shows the instant the mouse crosses the canvas boundary.
    override func resetCursorRects() {
        super.resetCursorRects()
        guard let viewModel = viewModel else { return }
        discardCursorRects()
        addCursorRect(bounds, cursor: cursor(for: viewModel.currentTool))
    }

    // Cursor-rect system handles tool cursor + revert-on-exit automatically
    // via resetCursorRects(). No tracking area or mouseEntered/Exited needed.

    // MARK: - Mouse Moved (cursor feedback)

    override func mouseMoved(with event: NSEvent) {
        guard let viewModel = viewModel else { return }

        // IMPORTANT: mouseMoved fires on the first-responder view regardless
        // of whether the pointer is actually inside self.bounds (since the
        // window has acceptsMouseMovedEvents = true). Bail early if the
        // mouse isn't over the canvas — otherwise we'd override the cursor
        // while the user hovers the sidebar, which is exactly the bug that
        // haunted the previous iteration.
        let viewPoint = convert(event.locationInWindow, from: nil)
        guard bounds.contains(viewPoint) else { return }

        // Only the transform tool needs per-position dynamic cursors.
        // Every other tool gets its static cursor via `resetCursorRects`,
        // which macOS also reverts automatically on exit.
        if viewModel.currentTool == .transform, let session = viewModel.transformSession {
            let canvasPoint = viewModel.transform.viewToCanvas(viewPoint, viewSize: bounds.size)
            let handle = hitTestTransformHandle(at: canvasPoint, session: session)
            TransformCursor.current(for: handle, dragging: false).set()
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

    /// Pen samples normally arrive as mouse events. When only the pressure changes — the
    /// pen is pressed harder without moving — AppKit sends a tablet event here instead.
    override func tabletPoint(with event: NSEvent) {
        guard let viewModel = viewModel, viewModel.isDrawing else { return }
        handleDrawingMouseDragged(event)
    }

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

    /// Two-finger twist on the trackpad turns the canvas about the pointer.
    override func rotate(with event: NSEvent) {
        guard let viewModel = viewModel else { return }
        let location = convert(event.locationInWindow, from: nil)
        let delta = CGFloat(event.rotation) * .pi / 180
        viewModel.transform.rotate(by: delta, at: location, viewSize: bounds.size)
        if event.phase == .ended, abs(viewModel.transform.rotation) < 2 * .pi / 180 {
            viewModel.transform.setRotation(0, at: location, viewSize: bounds.size)
        }
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
                viewModel.saveUndoSnapshot(renderer: renderer, description: "Select All", changing: .nothing)
                viewModel.selectAll()
            case "d":
                viewModel.saveUndoSnapshot(renderer: renderer, description: "Deselect", changing: .nothing)
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
                if activeLayer.isLocked { NSSound.beep(); return }
                viewModel.saveUndoSnapshot(renderer: renderer, description: "Delete Selection", changing: .layer(activeLayer))
                renderer.clearInsideSelection(path: path, layer: activeLayer, context: renderer.context)
                renderer.updateThumbnail(for: activeLayer)
            }
            return
        }

        // A stroke in progress keeps its tool, brush and colours: the renderer reads them
        // every frame, and a tool change mid-stroke would leave the stroke unfinished
        if viewModel.isDrawing { return }

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

        // Each pen keeps its own pressure curve
        viewModel.pressureCurve = AppPreferences.shared.pressureCurve(forPen: TabletEventHandler.currentPenKey)

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
