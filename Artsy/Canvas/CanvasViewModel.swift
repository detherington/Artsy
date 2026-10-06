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

    // Floating selection content (during move)
    var floatingTexture: MTLTexture? = nil
    var floatingOffset: CGPoint = .zero
    @Published var canvasBackgroundColor: (r: Double, g: Double, b: Double) = (0.10, 0.10, 0.10)
    @Published var isDistractionFree = false

    // Active stroke being drawn
    private(set) var activePath: StrokePath?
    var isDrawing = false

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

    // Transform tool — non-nil while transforming a layer.
    // Using objectWillChange publishing since TransformSession is a class.
    @Published var transformSession: TransformSession? = nil

    // MARK: - Document state
    /// URL this canvas is saved to, if any. Set after save/load.
    @Published var fileURL: URL? = nil
    /// True when there are unsaved changes.
    @Published var isDirty: Bool = false

    func markDirty() { isDirty = true }
    func markClean() { isDirty = false }

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
        if StrokeRecorder.isEnabledInDefaults {
            self.recorder = StrokeRecorder(canvasSize: canvasSize, fileURL: StrokeRecorder.newFileURL())
        }
    }

    /// - Parameter hasPressure: false for a mouse or trackpad, whose "pressure" is a constant.
    func beginStroke(point: StrokePoint, hasPressure: Bool = true) {
        strokeHasPressure = hasPressure
        recorder?.beginStroke(settingsFrom: self, firstPoint: point)
        smoother.mode = smoothingMode
        smoother.strength = smoothingStrength
        smoother.zoom = transform.scale
        smoother.begin()
        let path = StrokePath(style: StrokePath.Style(
            brushSize: brushSize,
            pressureCurve: pressureCurve,
            dynamics: currentBrush.pressureDynamics,
            easeLength: hasPressure || !easesStrokesWithoutPressure ? 0 : Self.easeLength(forBrushSize: brushSize)
        ))
        path.append(smoother.filter(point))
        activePath = path
        strokeIsSettled = false
        isDrawing = true
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

    func continueStroke(point: StrokePoint) {
        recorder?.append(point)
        guard isDrawing else { return }
        activePath?.append(smoother.filter(point))
    }

    /// Call after the renderer has finalized the stroke — it still needs the points.
    func endStroke() {
        smoother.end()
        recorder?.endStroke()
        activePath = nil
        isDrawing = false
    }

    // MARK: - Undo / Redo

    /// Call BEFORE performing any undoable action (stroke, layer add/remove, etc.)
    func saveUndoSnapshot(renderer: CanvasRenderer, description: String = "Action") {
        guard let layerStack = layerStack else { return }
        undoManager.saveSnapshot(
            layerStack: layerStack,
            selectionPath: selectionPath,
            context: renderer.context,
            description: description
        )
        markDirty()
    }

    func performUndo(renderer: CanvasRenderer) {
        guard let layerStack = layerStack else { return }
        undoManager.undo(layerStack: layerStack, viewModel: self, context: renderer.context)
        markDirty()
        DispatchQueue.global(qos: .userInitiated).async {
            renderer.updateAllThumbnails(in: layerStack)
        }
    }

    func performRedo(renderer: CanvasRenderer) {
        guard let layerStack = layerStack else { return }
        undoManager.redo(layerStack: layerStack, viewModel: self, context: renderer.context)
        markDirty()
        DispatchQueue.global(qos: .userInitiated).async {
            renderer.updateAllThumbnails(in: layerStack)
        }
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
