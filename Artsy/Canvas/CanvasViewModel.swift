import Foundation
import Combine
import Metal
import CoreGraphics

enum RightPanelMode {
    case full
    case condensed
}

extension Notification.Name {
    static let rightPanelToggled = Notification.Name("rightPanelToggled")
    static let tabletProximityChanged = Notification.Name("tabletProximityChanged")
    static let enterDistractionFree = Notification.Name("enterDistractionFree")
    static let exitDistractionFree = Notification.Name("exitDistractionFree")
}

final class CanvasViewModel: ObservableObject {
    // Canvas state
    let canvasSize: CGSize
    @Published var transform = CanvasTransform()

    // Drawing state
    @Published var currentBrush: BrushDescriptor = .hardRound {
        didSet {
            // Each brush keeps its own size and smoothing amount: remember the outgoing
            // brush's, restore the incoming brush's (or start from the brush's own values
            // the first time it's picked).
            guard currentBrush.id != oldValue.id else { return }
            sizeByBrush[oldValue.id] = brushSize
            brushSize = sizeByBrush[currentBrush.id] ?? currentBrush.baseSize
            smoothingByBrush[oldValue.id] = smoothingStrength
            smoothingStrength = smoothingByBrush[currentBrush.id] ?? currentBrush.smoothing
        }
    }
    private var sizeByBrush: [UUID: Float] = [:]
    private var smoothingByBrush: [UUID: Float] = [:]
    @Published var currentColor: StrokeColor = .black
    @Published var pressureCurve: PressureCurve = .linear
    @Published var brushSize: Float = 12
    @Published var brushOpacity: Float = 1.0
    @Published var isErasing = false
    @Published var isRightPanelVisible = true
    @Published var rightPanelMode: RightPanelMode = .full
    @Published var currentTool: ToolType = .brush
    @Published var selectionMode: SelectionMode = .rectangle
    @Published var selectionPath: CGPath? = nil

    // Shape tool state
    @Published var currentShape: ShapeMode = .rectangle
    @Published var shapeStrokeEnabled: Bool = true
    @Published var shapeFillEnabled: Bool = false
    @Published var shapeStrokeWidth: CGFloat = 3.0
    @Published var previewShapePath: CGPath? = nil

    // Floating selection content (during move), and its thickness if the layer has any
    var floatingTexture: MTLTexture? = nil
    var floatingHeight: MTLTexture? = nil
    var floatingOffset: CGPoint = .zero
    @Published var canvasBackgroundColor: (r: Double, g: Double, b: Double) = (0.10, 0.10, 0.10)
    @Published var isDistractionFree = false

    // Active stroke being drawn
    private(set) var activePath: StrokePath?
    var isDrawing = false
    /// The stroke snapped to the shape it was going for, while the pen holds still at its
    /// end. Drawn in place of `activePath` until the pen moves on or lifts.
    private(set) var snappedPath: StrokePath?
    /// What the stroke snapped to, for the status bar.
    @Published private(set) var snappedShapeName: String?
    /// Where the pen was when the stroke snapped; moving on from there snaps back.
    private var snapAnchor: CGPoint?
    /// The path the renderer draws: the snapped shape when there is one.
    var drawnPath: StrokePath? { snappedPath ?? activePath }
    /// Hold the pen still at the end of a stroke to snap it to a line, circle, rectangle or
    /// polygon. Follows the preference unless set explicitly.
    var snapsShapesOnHold: Bool {
        get { snapsShapesOverride ?? AppPreferences.shared.snapShapesOnHold }
        set { snapsShapesOverride = newValue }
    }
    private var snapsShapesOverride: Bool?
    /// How long the pen holds still before the stroke snaps.
    static let shapeSnapHold: TimeInterval = 0.6

    // Layer stack (set up by renderer)
    var layerStack: LayerStack!

    // Undo manager
    let undoManager = CanvasUndoManager()

    // Stroke smoothing
    let smoother = StrokeSmoother()
    @Published var smoothingMode: SmoothingMode = .oneEuro
    @Published var smoothingStrength: Float = 0.5
    /// Ease strokes in and out when the input has no pressure of its own (a mouse).
    /// Follows the preference unless set explicitly.
    var easesStrokesWithoutPressure: Bool {
        get { easesStrokesOverride ?? AppPreferences.shared.easeStrokesWithoutPressure }
        set { easesStrokesOverride = newValue }
    }
    private var easesStrokesOverride: Bool?

    /// Captures raw input for replay in tests; nil unless the `recordStrokes` default is on.
    var recorder: StrokeRecorder?

    // Swap colors
    @Published var foregroundColor: StrokeColor = .black
    @Published var swapBackgroundColor: StrokeColor = .white

    // Bucket fill tool — tolerance in 0-255 color distance units per channel.
    @Published var fillTolerance: Int = 16

    // Symmetry — mirrors each stroke around the canvas center.
    @Published var symmetryMode: SymmetryMode = .off

    /// A grid and guide lines over the canvas, which the pen snaps to.
    @Published var guides = CanvasGuides()

    /// `point` pulled onto any guide within reach, at the current zoom.
    private func snappedToGuides(_ point: StrokePoint) -> StrokePoint {
        guard guides.snapsAnything else { return point }
        let position = guides.snapped(point.position, zoom: transform.scale)
        guard position != point.position else { return point }
        return StrokePoint(position: position, pressure: point.pressure, tiltX: point.tiltX, tiltY: point.tiltY,
                           rotation: point.rotation, timestamp: point.timestamp)
    }

    // Transform tool — non-nil while transforming a layer.
    // Using objectWillChange publishing since TransformSession is a class.
    @Published var transformSession: TransformSession? = nil

    // MARK: - Document state
    /// URL this canvas is saved to, if any. Set after save/load.
    @Published var fileURL: URL? = nil
    /// True when there are unsaved changes.
    @Published var isDirty: Bool = false

    /// Texture memory this canvas holds: its layers (and their thickness), the undo history
    /// and the renderer's scratch textures.
    var memoryUseBytes: Int {
        let pixels = Int(canvasSize.width) * Int(canvasSize.height)
        var bytes = 0
        for layer in layerStack?.layers ?? [] {
            bytes += pixels * (layer.heightTexture == nil ? 8 : 10)
        }
        // Composite, blend scratch, two stroke textures and the composite height map
        bytes += pixels * (8 * 4 + 2)
        bytes += undoManager.textureBytes
        return bytes
    }

    func markDirty() {
        isDirty = true
        noteContentChanged()
    }
    func markClean() { isDirty = false }

    /// Goes up whenever a layer's pixels may have changed outside a stroke, so the renderer
    /// knows the composite is stale. `markDirty` counts; so do the tools that write pixels.
    private(set) var contentVersion = 0
    func noteContentChanged() { contentVersion += 1 }

    /// Short display name for prompts. Falls back to "Untitled".
    var displayName: String {
        fileURL?.deletingPathExtension().lastPathComponent ?? "Untitled"
    }

    init(canvasSize: CGSize = CGSize(width: 2048, height: 2048)) {
        self.canvasSize = canvasSize
        // Apply user preferences
        let prefs = AppPreferences.shared
        self.currentBrush = prefs.defaultBrush
        self.brushSize = Float(prefs.defaultBrushSize)
        self.smoothingMode = prefs.smoothingMode
        self.smoothingStrength = prefs.defaultBrush.smoothing
        self.pressureCurve = prefs.pressureCurve(forPen: TabletEventHandler.currentPenKey)
        if StrokeRecorder.isEnabledInDefaults {
            self.recorder = StrokeRecorder(canvasSize: canvasSize, fileURL: StrokeRecorder.newFileURL())
        }
    }

    /// - Parameter hasPressure: false for a mouse or trackpad, whose "pressure" is a constant.
    func beginStroke(point rawPoint: StrokePoint, hasPressure: Bool = true) {
        guard rawPoint.isFinite else { return }   // a tablet glitch, not a stroke
        // A shape the last stroke was left snapped to has nothing to do with this one
        snappedPath = nil
        snappedShapeName = nil
        snapAnchor = nil
        strokeHasPressure = hasPressure
        recorder?.beginStroke(settingsFrom: self, firstPoint: rawPoint)
        let point = snappedToGuides(rawPoint)
        smoother.mode = smoothingMode
        smoother.strength = smoothingStrength
        smoother.zoom = transform.scale
        smoother.begin()
        let path = StrokePath(style: StrokePath.Style(
            brushSize: brushSize,
            pressureCurve: pressureCurve,
            dynamics: currentBrush.pressureDynamics,
            tilt: currentBrush.tiltDynamics,
            velocity: currentBrush.velocityDynamics,
            spraysWhileResting: { if case .stamp(let s) = currentBrush.rendering { return s.holdRate > 0 } else { return false } }(),
            easeLength: hasPressure || !easesStrokesWithoutPressure ? 0 : Self.easeLength(forBrushSize: brushSize)
        ))
        path.append(smoother.filter(point))
        activePath = path
        lastInput = point
        strokeIsSettled = false
        isDrawing = true
    }

    /// The last sample the pen sent, before smoothing.
    private var lastInput: StrokePoint?

    /// Call once per frame while the pen is down. If no sample has arrived since the last
    /// frame the pen is resting, which the stroke still needs to know about: smoothing
    /// catches up to a resting pen, and an airbrush keeps spraying.
    func holdStroke(at time: TimeInterval) {
        guard isDrawing, let last = lastInput, time - last.timestamp > 0.004 else { return }
        continueStroke(point: StrokePoint(
            position: last.position, pressure: last.pressure, tiltX: last.tiltX, tiltY: last.tiltY,
            rotation: last.rotation, timestamp: time
        ))
    }

    /// How far a stroke without pen pressure takes to reach full width: a few brush widths.
    static func easeLength(forBrushSize size: Float) -> CGFloat {
        CGFloat(min(max(size * 2.5, 8), 160))
    }

    /// Whether the stroke in progress comes from a device that reports pressure.
    private(set) var strokeHasPressure = true
    private var strokeIsSettled = false

    /// The pen has lifted: bring the stroke to where it actually lifted, if smoothing left
    /// it short. The renderer calls this before it draws the stroke's last points.
    func settleStroke() {
        guard isDrawing, !strokeIsSettled else { return }
        strokeIsSettled = true
        if let point = smoother.catchUpPoint() {
            activePath?.append(point)
        }
    }

    func continueStroke(point rawPoint: StrokePoint) {
        guard rawPoint.isFinite else { return }
        recorder?.append(rawPoint)
        guard isDrawing else { return }
        let point = snappedToGuides(rawPoint)
        lastInput = point
        activePath?.append(smoother.filter(point))
        checkShapeSnap()
    }

    /// Snap the stroke to a shape once the pen has held still long enough at its end; snap
    /// back to the stroke as drawn once the pen moves on, and keep drawing it.
    private func checkShapeSnap() {
        // A brush that sprays while the pen rests is held still on purpose
        guard snapsShapesOnHold, currentBrush.smudgeSettings == nil, let path = activePath,
              !path.style.spraysWhileResting, let end = path.samples.last?.position else { return }
        if snappedPath != nil {
            if let anchor = snapAnchor, hypot(end.x - anchor.x, end.y - anchor.y) > 6 {
                snappedPath = nil
                snappedShapeName = nil
                snapAnchor = nil
            }
            return
        }
        guard path.holdDuration >= Self.shapeSnapHold, path.samples.count >= 8,
              let shape = ShapeRecognizer.recognize(path.samples.map(\.position)) else { return }

        // The shape drawn as a stroke itself, at the stroke's usual pressure, tilt and pace,
        // so a brush that answers to any of them draws it the way it drew the stroke
        func median(_ values: [Float]) -> Float {
            let sorted = values.sorted()
            return sorted[sorted.count / 2]
        }
        let samples = path.samples
        let pressure = median(samples.map(\.pressure))
        let tiltX = median(samples.map(\.tiltX)), tiltY = median(samples.map(\.tiltY))
        let rotation = median(samples.map(\.rotation))
        let drawingTime = max(samples[samples.count - 1].timestamp - samples[0].timestamp - path.holdDuration, 0.05)
        let speed = max(Double(path.points[path.points.count - 1].distance) / drawingTime, 1)   // px per second
        var style = path.style
        style.easeLength = 0
        let snapped = StrokePath(style: style)
        for (index, position) in shape.points(spacing: 2).enumerated() {
            snapped.append(StrokePoint(position: position, pressure: pressure, tiltX: tiltX, tiltY: tiltY,
                                       rotation: rotation, timestamp: Double(index) * 2 / speed))
        }
        snappedPath = snapped
        snappedShapeName = shape.name
        snapAnchor = end
    }

    /// Call after the renderer has finalized the stroke — it still needs the points.
    func endStroke() {
        smoother.end()
        recorder?.endStroke()
        activePath = nil
        snappedPath = nil
        snappedShapeName = nil
        snapAnchor = nil
        isDrawing = false
    }

    // MARK: - Undo / Redo

    /// Call BEFORE performing any undoable action other than a stroke, saying which
    /// layers' pixels it will change (`.nothing` for a selection or a change to the layer
    /// list; `.layer(x)` for a fill, a transform…). Only those are copied; a snapshot of
    /// everything costs a copy of every layer.
    func saveUndoSnapshot(renderer: CanvasRenderer, description: String = "Action",
                          changing scope: CanvasUndoManager.Scope = .everything) {
        guard let layerStack = layerStack else { return }
        undoManager.saveSnapshot(
            layerStack: layerStack,
            selectionPath: selectionPath,
            scope: scope,
            context: renderer.context,
            description: description
        )
        markDirty()
    }

    func performUndo(renderer: CanvasRenderer) {
        guard let layerStack = layerStack else { return }
        undoManager.undo(layerStack: layerStack, viewModel: self, context: renderer.context)
        markDirty()
        renderer.updateAllThumbnails(in: layerStack)
    }

    func performRedo(renderer: CanvasRenderer) {
        guard let layerStack = layerStack else { return }
        undoManager.redo(layerStack: layerStack, viewModel: self, context: renderer.context)
        markDirty()
        renderer.updateAllThumbnails(in: layerStack)
    }

    // MARK: - Color

    func toggleRightPanel() {
        isRightPanelVisible.toggle()
        NotificationCenter.default.post(name: .rightPanelToggled, object: self)
    }

    func toggleRightPanelMode() {
        rightPanelMode = rightPanelMode == .full ? .condensed : .full
        // Ensure visible when toggling between modes
        if !isRightPanelVisible {
            isRightPanelVisible = true
        }
        NotificationCenter.default.post(name: .rightPanelToggled, object: self)
    }

    // MARK: - Selection

    func selectAll() {
        selectionPath = CGPath(rect: CGRect(origin: .zero, size: canvasSize), transform: nil)
    }

    func clearSelection() {
        selectionPath = nil
    }

    func swapColors() {
        let temp = foregroundColor
        foregroundColor = swapBackgroundColor
        swapBackgroundColor = temp
        currentColor = foregroundColor
    }

    func resetColors() {
        foregroundColor = .black
        swapBackgroundColor = .white
        currentColor = .black
    }
}
