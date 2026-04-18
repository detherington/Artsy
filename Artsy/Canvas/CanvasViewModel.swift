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
    @Published var currentBrush: BrushDescriptor = .hardRound
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
    var activeStrokePoints: [StrokePoint] = []
    var isDrawing = false

    // Stroke history per layer
    var strokeHistory: [UUID: [Stroke]] = [:]

    // Layer stack (set up by renderer)
    var layerStack: LayerStack!

    // Undo manager
    let undoManager = CanvasUndoManager()

    // Interpolator
    let interpolator = StrokeInterpolator()

    // Stroke smoothing
    let smoother = StrokeSmoother()
    @Published var smoothingMode: SmoothingMode = .none
    @Published var smoothingStrength: Float = 0.5

    // Swap colors
    @Published var foregroundColor: StrokeColor = .black
    @Published var swapBackgroundColor: StrokeColor = .white

    // Bucket fill tool — tolerance in 0-255 color distance units per channel.
    @Published var fillTolerance: Int = 16

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
    }

    var activeLayerID: UUID {
        layerStack?.activeLayer?.id ?? UUID()
    }

    func beginStroke(point: StrokePoint) {
        smoother.mode = smoothingMode
        smoother.strength = smoothingStrength
        smoother.begin()
        let smoothed = smoother.filter(point)
        activeStrokePoints = [smoothed]
        isDrawing = true
    }

    func continueStroke(point: StrokePoint) {
        let smoothed = smoother.filter(point)
        activeStrokePoints.append(smoothed)
    }

    func endStroke() -> Stroke? {
        smoother.end()
        guard !activeStrokePoints.isEmpty else {
            isDrawing = false
            return nil
        }

        let layerID = activeLayerID

        var stroke = Stroke(
            brushDescriptor: currentBrush,
            color: currentColor,
            rawPoints: activeStrokePoints,
            layerID: layerID
        )

        let interpolated = interpolator.interpolate(
            points: activeStrokePoints,
            spacing: currentBrush.spacing,
            brushSize: brushSize,
            pressureCurve: pressureCurve,
            dynamics: currentBrush.pressureDynamics
        )
        stroke.interpolatedPoints = interpolated

        if strokeHistory[layerID] == nil {
            strokeHistory[layerID] = []
        }
        strokeHistory[layerID]?.append(stroke)

        activeStrokePoints = []
        isDrawing = false

        return stroke
    }

    func currentInterpolatedPoints() -> [InterpolatedPoint] {
        guard activeStrokePoints.count >= 2 else {
            if let p = activeStrokePoints.first {
                let mapped = pressureCurve.map(p.pressure)
                return [InterpolatedPoint(
                    position: p.position,
                    pressure: mapped,
                    width: currentBrush.pressureDynamics.size(for: mapped) * brushSize,
                    opacity: currentBrush.pressureDynamics.opacity(for: mapped),
                    angle: 0
                )]
            }
            return []
        }

        return interpolator.interpolate(
            points: activeStrokePoints,
            spacing: currentBrush.spacing,
            brushSize: brushSize,
            pressureCurve: pressureCurve,
            dynamics: currentBrush.pressureDynamics
        )
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
