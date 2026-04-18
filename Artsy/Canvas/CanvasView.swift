import AppKit
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
            break

        case .fill:
            handleFillMouseDown(event)
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
                if event.modifierFlags.contains(.shift) {
                    viewModel.performRedo(renderer: renderer)
                } else {
                    viewModel.performUndo(renderer: renderer)
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
