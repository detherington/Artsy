import Foundation
import Combine
import Metal
import CoreGraphics

public extension Notification.Name {
    public static let tabletProximityChanged = Notification.Name("tabletProximityChanged")
}

public final class CanvasViewModel: ObservableObject {
    // Canvas state
    public let canvasSize: CGSize
    @Published public var transform = CanvasTransform()

    // Drawing state
    @Published public var currentBrush: BrushDescriptor = .hardRound {
        didSet {
            // Each brush keeps its own size and smoothing amount: remember the outgoing
            // brush's, restore the incoming brush's (or start from the brush's own values
            // the first time it's picked).
            guard currentBrush.id != oldValue.id else { return }
            sizeByBrush[oldValue.id] = brushSize
            brushSize = sizeByBrush[currentBrush.id] ?? currentBrush.baseSize
            smoothingByBrush[oldValue.id] = smoothingStrength
            smoothingStrength = smoothingByBrush[currentBrush.id] ?? currentBrush.smoothing
            gradeByBrush[oldValue.id] = pencilGrade
            pencilGrade = gradeByBrush[currentBrush.id] ?? (remembersGrades ? AppPreferences.shared.pencilGrade(for: currentBrush.id) : .hb)
        }
    }
    private var sizeByBrush: [UUID: Float] = [:]
    private var smoothingByBrush: [UUID: Float] = [:]
    private var gradeByBrush: [UUID: PencilGrade] = [:]
    /// The grade a graphite brush paints at (`PencilGrade`): a live control, like the size,
    /// remembered per brush and across launches. HB for a brush that is not graphite.
    @Published public var pencilGrade: PencilGrade = .hb {
        didSet { if remembersGrades { AppPreferences.shared.setPencilGrade(pencilGrade, for: currentBrush.id) } }
    }
    /// Whether grades are kept in the preferences; off for tests and previews.
    public var remembersGrades = true
    /// The key of the pen in use, which picks its pressure curve: the platform supplies it
    /// (the Mac: the tablet's device id), "default" otherwise.
    public static var currentPenKey: () -> String = { "default" }
    /// The brush as it paints: the current brush at its grade.
    public var strokeBrush: BrushDescriptor { currentBrush.graded(pencilGrade) }
    @Published public var currentColor: StrokeColor = .black
    @Published public var pressureCurve: PressureCurve = .linear
    @Published public var brushSize: Float = 12
    @Published public var brushOpacity: Float = 1.0
    @Published public var isErasing = false
    /// The bar, the rail and the dock out of the way, for the canvas alone (Tab).
    @Published public var isChromeHidden = false
    /// Tint the active layer's paint that is still wet, on the canvas.
    @Published public var showsWetPaint = false

    /// Dry the active layer's paint all over, at once.
    public func dryActiveLayer() {
        layerStack?.activeLayer?.dry()
    }
    /// Layers in a panel beside the canvas on a wide window, rather than a pop-up from
    /// the bar. Remembered across launches.
    @Published public var isLayersDocked: Bool = AppPreferences.shared.layersDocked {
        didSet { AppPreferences.shared.layersDocked = isLayersDocked }
    }
    @Published public var currentTool: ToolType = .brush
    @Published public var selectionMode: SelectionMode = .rectangle
    @Published public var selectionPath: CGPath? = nil

    // Shape tool state
    @Published public var currentShape: ShapeMode = .rectangle
    @Published public var shapeStrokeEnabled: Bool = true
    @Published public var shapeFillEnabled: Bool = false
    @Published public var shapeStrokeWidth: CGFloat = 3.0
    @Published public var previewShapePath: CGPath? = nil

    // Floating selection content (during move), and its thickness if the layer has any
    public var floatingTexture: MTLTexture? = nil
    public var floatingHeight: MTLTexture? = nil
    public var floatingOffset: CGPoint = .zero
    @Published public var canvasBackgroundColor: (r: Double, g: Double, b: Double) = (0.10, 0.10, 0.10)

    // Active stroke being drawn
    public private(set) var activePath: StrokePath?
    public var isDrawing = false
    /// The stroke snapped to the shape it was going for, while the pen holds still at its
    /// end. Drawn in place of `activePath` until the pen moves on or lifts.
    public private(set) var snappedPath: StrokePath?
    /// What the stroke snapped to, for the status bar.
    @Published public private(set) var snappedShapeName: String?
    /// Where the pen was when the stroke snapped; moving on from there snaps back.
    private var snapAnchor: CGPoint?
    /// The path the renderer draws: the snapped shape when there is one.
    public var drawnPath: StrokePath? { snappedPath ?? activePath }
    /// Hold the pen still at the end of a stroke to snap it to a line, circle, rectangle or
    /// polygon. Follows the preference unless set explicitly.
    public var snapsShapesOnHold: Bool {
        get { snapsShapesOverride ?? AppPreferences.shared.snapShapesOnHold }
        set { snapsShapesOverride = newValue }
    }
    private var snapsShapesOverride: Bool?
    /// How long the pen holds still before the stroke snaps.
    public static let shapeSnapHold: TimeInterval = 0.6

    // Layer stack (set up by renderer)
    public var layerStack: LayerStack!

    // Undo manager
    public let undoManager = CanvasUndoManager()

    // Stroke smoothing
    public let smoother = StrokeSmoother()
    @Published public var smoothingMode: SmoothingMode = .oneEuro
    @Published public var smoothingStrength: Float = 0.5
    /// Ease strokes in and out when the input has no pressure of its own (a mouse).
    /// Follows the preference unless set explicitly.
    public var easesStrokesWithoutPressure: Bool {
        get { easesStrokesOverride ?? AppPreferences.shared.easeStrokesWithoutPressure }
        set { easesStrokesOverride = newValue }
    }
    private var easesStrokesOverride: Bool?
    /// Pressure from speed when the input has no pressure of its own (`PressureFromSpeed`).
    /// Follows the preference unless set explicitly.
    public var pressureFromSpeed: Bool {
        get { pressureFromSpeedOverride ?? AppPreferences.shared.pressureFromSpeed }
        set { pressureFromSpeedOverride = newValue }
    }
    private var pressureFromSpeedOverride: Bool?
    private var speedPressure = PressureFromSpeed()

    /// The sample with its pressure from its speed, for an input that reports none.
    private func substitutingPressure(_ point: StrokePoint, from speed: inout PressureFromSpeed) -> StrokePoint {
        guard !strokeHasPressure, pressureFromSpeed else { return point }
        let pressure = speed.pressure(for: point)
        return StrokePoint(position: point.position, pressure: pressure, tiltX: point.tiltX, tiltY: point.tiltY,
                           rotation: point.rotation, timestamp: point.timestamp)
    }

    /// Captures raw input for replay in tests; nil unless the `recordStrokes` default is on.
    public var recorder: StrokeRecorder?

    // Swap colors
    @Published public var foregroundColor: StrokeColor = .black
    @Published public var swapBackgroundColor: StrokeColor = .white

    // Bucket fill tool — tolerance in 0-255 color distance units per channel.
    @Published public var fillTolerance: Int = 16

    // Symmetry — mirrors each stroke around the canvas center.
    @Published public var symmetryMode: SymmetryMode = .off
    /// The paper's lean, which water runs with: positive x to the right, positive y down
    /// the screen, each at most 1. Level when the window opens.
    @Published public var canvasTilt: SIMD2<Float> = .zero

    /// A grid and guide lines over the canvas, which the pen snaps to.
    @Published public var guides = CanvasGuides()

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
    @Published public var transformSession: TransformSession? = nil

    // MARK: - Document state
    /// URL this canvas is saved to, if any. Set after save/load.
    @Published public var fileURL: URL? = nil
    /// True when there are unsaved changes.
    @Published public var isDirty: Bool = false

    /// Texture memory this canvas holds: its layers (and their thickness), the undo history
    /// and the renderer's scratch textures.
    public var memoryUseBytes: Int {
        let pixels = Int(canvasSize.width) * Int(canvasSize.height)
        var bytes = 0
        for layer in layerStack?.layers ?? [] {
            bytes += pixels * (8 + (layer.heightTexture == nil ? 0 : 2) + (layer.wetTexture == nil ? 0 : 2))
            if let water = layer.water {
                let region = water.region.width * water.region.height
                bytes += region * 8 + region / (water.scale * water.scale) * 48
            }
        }
        // Composite and its height map, each with mip levels (a third again), blend
        // scratch and two stroke textures
        bytes += pixels * (8 + 2) * 4 / 3 + pixels * 8 * 3
        bytes += undoManager.textureBytes
        return bytes
    }

    public func markDirty() {
        isDirty = true
        noteContentChanged()
    }
    public func markClean() { isDirty = false }

    /// Goes up whenever a layer's pixels may have changed outside a stroke, so the renderer
    /// knows the composite is stale. `markDirty` counts; so do the tools that write pixels.
    public private(set) var contentVersion = 0
    public func noteContentChanged() { contentVersion += 1 }

    /// What an unsaved canvas is called: the window's title ("Canvas 2"), so the bar and
    /// the title bar agree.
    @Published public var untitledName = "Untitled"

    /// Short display name for prompts and the bar: the file's name once saved.
    public var displayName: String {
        fileURL?.deletingPathExtension().lastPathComponent ?? untitledName
    }

    public init(canvasSize: CGSize = CGSize(width: 2048, height: 2048)) {
        self.canvasSize = canvasSize
        // Apply user preferences
        let prefs = AppPreferences.shared
        self.currentBrush = prefs.defaultBrush
        self.pencilGrade = prefs.pencilGrade(for: prefs.defaultBrush.id)
        self.brushSize = Float(prefs.defaultBrushSize)
        self.smoothingMode = prefs.smoothingMode
        self.smoothingStrength = prefs.defaultBrush.smoothing
        self.pressureCurve = prefs.pressureCurve(forPen: Self.currentPenKey())
        if StrokeRecorder.isEnabledInDefaults {
            self.recorder = StrokeRecorder(canvasSize: canvasSize, fileURL: StrokeRecorder.newFileURL())
        }
    }

    /// - Parameter hasPressure: false for a mouse or trackpad, whose "pressure" is a constant.
    public func beginStroke(point rawPoint: StrokePoint, hasPressure: Bool = true) {
        beginStroke(point: rawPoint, input: hasPressure ? .pen : .hand)
    }

    /// - Parameter input: what is drawing: a pen with pressure of its own, a pen without
    ///   (the USB-C Apple Pencil), or a hand, a mouse or a trackpad. The two without pressure
    ///   take theirs from speed, each at its own pace. A pen without pressure also starts
    ///   out with the Soft curve, unless a curve was chosen for this pen, and widens as it
    ///   leans without fading, since fading stood for the lighter touch of a pen laid on its
    ///   side, which this pen cannot tell from pressing.
    public func beginStroke(point rawPoint: StrokePoint, input: StrokeInput) {
        guard rawPoint.isFinite else { return }   // a tablet glitch, not a stroke
        // A shape the last stroke was left snapped to has nothing to do with this one
        snappedPath = nil
        snappedShapeName = nil
        snapAnchor = nil
        strokeInput = input
        strokeHasPressure = input.hasPressure
        curveSoftenedForPen = false
        if input == .penWithoutPressure, pressureCurve == .linear,
           AppPreferences.shared.pressureCurves[Self.currentPenKey()] == nil {
            pressureCurve = .soft   // a pen that cannot press gets the curve that presses easily
            curveSoftenedForPen = true
        }
        recorder?.beginStroke(settingsFrom: self, firstPoint: rawPoint)
        speedPressure = PressureFromSpeed(zoom: Float(transform.scale),   // the hand's speed is on the screen
                                          pace: input == .penWithoutPressure ? .pen : .hand)
        let point = snappedToGuides(substitutingPressure(rawPoint, from: &speedPressure))
        smoother.mode = smoothingMode
        smoother.strength = smoothingStrength
        smoother.zoom = transform.scale
        smoother.begin()
        let path = StrokePath(style: StrokePath.Style(
            brushSize: brushSize,
            pressureCurve: pressureCurve,
            dynamics: strokeBrush.pressureDynamics,
            tilt: input == .penWithoutPressure ? currentBrush.tiltDynamics?.withoutFading : currentBrush.tiltDynamics,
            velocity: currentBrush.velocityDynamics,
            spraysWhileResting: { if case .stamp(let s) = currentBrush.rendering { return s.holdRate > 0 } else { return false } }(),
            easeLength: input.hasPressure || !easesStrokesWithoutPressure ? 0 : Self.easeLength(forBrushSize: brushSize)
        ))
        path.append(smoother.filter(point))
        activePath = path
        lastInput = point
        sampleArrivedSinceFrame = true
        lastFrameTime = nil
        restSamplesInStroke = 0
        strokeIsSettled = false
        isDrawing = true
    }

    /// The last sample the pen sent, before smoothing.
    private var lastInput: StrokePoint?
    /// Whether a sample has arrived since the last frame, and when that frame was.
    private var sampleArrivedSinceFrame = false
    private var lastFrameTime: TimeInterval?
    /// Rest samples `holdStroke` has added since pen-down, for the diagnostics log.
    public private(set) var restSamplesInStroke = 0

    /// Call once per frame while the pen is down. A frame that no sample arrived before
    /// means the pen is resting, which the stroke still needs to know about: smoothing
    /// catches up to a resting pen, and an airbrush keeps spraying.
    ///
    /// Resting is a frame without a sample, not a sample older than the frame: a tablet's
    /// samples reach the app late (20–70 ms behind the frame clock on an XP-Pen), so by
    /// age every sample would look like a rest, and a rest a frame would be added to every
    /// frame of a moving stroke. The rest sample keeps the pen's own clock, a frame on from
    /// the last sample, so the next real sample is not in its past: the smoother goes by
    /// time, and a sample from the past reads as a pen moving impossibly fast.
    public func holdStroke(at time: TimeInterval) {
        guard isDrawing, let last = lastInput else { return }
        defer { sampleArrivedSinceFrame = false; lastFrameTime = time }
        guard !sampleArrivedSinceFrame, let lastFrame = lastFrameTime else { return }
        predictStroke([])   // a resting pen is going nowhere
        restSamplesInStroke += 1
        feed(StrokePoint(
            position: last.position, pressure: last.pressure, tiltX: last.tiltX, tiltY: last.tiltY,
            rotation: last.rotation, timestamp: last.timestamp + (time - lastFrame)
        ))
    }

    /// How far a stroke without pen pressure takes to reach full width: a few brush widths.
    public static func easeLength(forBrushSize size: Float) -> CGFloat {
        CGFloat(min(max(size * 2.5, 8), 160))
    }

    /// Whether the stroke in progress comes from a device that reports pressure.
    public private(set) var strokeHasPressure = true
    /// What is drawing the stroke in progress.
    public private(set) var strokeInput: StrokeInput = .pen

    /// The stroke in progress turned out to report pressure after all: a Pencil's force
    /// is estimated at first and its landing sample can read zero, so the view may have
    /// begun the stroke without pressure. From here on each sample's own pressure counts
    /// in place of the one from speed; what is drawn already keeps the pressure it had.
    public func strokeReportsPressure() {
        guard isDrawing, !strokeHasPressure else { return }
        strokeHasPressure = true
        strokeInput = .pen
        // The Soft curve was the default for a pen that cannot press; this one can
        if curveSoftenedForPen { pressureCurve = .linear; curveSoftenedForPen = false }
        recorder?.strokeReportsPressure()
    }
    /// Whether this stroke's Soft curve was the pen-without-pressure default, to take back
    /// should the pen turn out to press after all.
    private var curveSoftenedForPen = false
    private var strokeIsSettled = false

    /// The pen has lifted: bring the stroke to where it actually lifted, if smoothing left
    /// it short. The renderer calls this before it draws the stroke's last points.
    public func settleStroke() {
        guard isDrawing, !strokeIsSettled else { return }
        strokeIsSettled = true
        if let point = smoother.catchUpPoint() {
            activePath?.append(point)
        }
    }

    public func continueStroke(point rawPoint: StrokePoint) {
        sampleArrivedSinceFrame = true
        feed(rawPoint)
    }

    /// A sample from the pen, or a rest sample standing in for one, into the stroke.
    private func feed(_ rawPoint: StrokePoint) {
        guard rawPoint.isFinite else { return }
        recorder?.append(rawPoint)
        guard isDrawing else { return }
        let point = snappedToGuides(substitutingPressure(rawPoint, from: &speedPressure))
        lastInput = point
        activePath?.append(smoother.filter(point))
        checkShapeSnap()
    }

    /// Where the pen is expected next, a frame ahead: the predicted touches iOS offers
    /// with each event, readied like the real samples (pressure from speed, the guides,
    /// smoothing) without moving any of that on. The renderer draws the stroke's tail
    /// through them, and only the tail, so a wrong guess costs one frame and nothing is
    /// committed on its word. Replaced by the next event's; cleared while the pen rests.
    public private(set) var predictedSamples: [StrokePoint] = []
    /// Goes up every time `predictedSamples` changes, for the renderer.
    public private(set) var predictionVersion = 0

    public func predictStroke(_ samples: [StrokePoint]) {
        guard isDrawing else { return }
        if samples.isEmpty, predictedSamples.isEmpty { return }
        var speed = speedPressure
        let readied = samples.filter(\.isFinite).map { snappedToGuides(substitutingPressure($0, from: &speed)) }
        predictedSamples = smoother.preview(readied)
        predictionVersion += 1
    }

    /// Snap the stroke to a shape once the pen has held still long enough at its end; snap
    /// back to the stroke as drawn once the pen moves on, and keep drawing it.
    private func checkShapeSnap() {
        // A brush that sprays while the pen rests is held still on purpose
        guard snapsShapesOnHold, currentBrush.smudgeSettings == nil, let path = activePath,
              !path.style.spraysWhileResting, let end = path.samples.last?.position else { return }
        if snappedPath != nil {
            if let anchor = snapAnchor, hypot(end.x - anchor.x, end.y - anchor.y) > 6 {
                DiagnosticsLog.shared.note(.stroke, "moved on from \(snappedShapeName ?? "the shape"): back to the stroke as drawn")
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
        DiagnosticsLog.shared.note(.stroke, String(format: "held %.2f s: snapped to %@", path.holdDuration, shape.name))
    }

    /// Turn raw-input recording on or off for this canvas (Help ▸ Diagnostics ▸ Record Strokes).
    public func setStrokeRecording(_ on: Bool) {
        recorder = on ? StrokeRecorder(canvasSize: canvasSize, fileURL: StrokeRecorder.newFileURL()) : nil
    }

    /// One line about the stroke in progress for the diagnostics log: the brush, how many
    /// samples came at what rate, the pressure and tilt the pen reported, how long it was
    /// held, whether it snapped. Nil when no stroke is in progress.
    public func strokeSummary() -> String? {
        guard let path = activePath, let first = path.samples.first, let last = path.samples.last else { return nil }
        let samples = path.samples
        let duration = last.timestamp - first.timestamp
        let pressures = samples.map(\.pressure)
        let tilt = samples.map { hypot($0.tiltX, $0.tiltY) }.max() ?? 0
        let length = path.points.last?.distance ?? 0
        return String(format: "%@ %.0f px: %d samples in %.2f s (%.0f/s), %.0f px long, pressure %.2f–%.2f, tilt %.2f, held %.2f s%@%@%@",
                      currentBrush.name, brushSize, samples.count, duration, duration > 0 ? Double(samples.count) / duration : 0,
                      Double(length), pressures.min() ?? 0, pressures.max() ?? 0, tilt, path.holdDuration,
                      restSamplesInStroke > 0 ? ", \(restSamplesInStroke) rest samples" : "",
                      strokeHasPressure ? "" : (pressureFromSpeed ? (strokeInput == .penWithoutPressure ? ", pressure from a pen's speed" : ", pressure from speed") : ", no pressure"),
                      snappedShapeName.map { ", snapped to \($0)" } ?? "")
    }

    /// Call after the renderer has finalized the stroke — it still needs the points.
    public func endStroke() {
        smoother.end()
        recorder?.endStroke()
        predictedSamples = []
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
    public func saveUndoSnapshot(renderer: CanvasRenderer, description: String = "Action",
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
        let copies: String
        switch scope {
        case .nothing: copies = "copying nothing"
        case .layers(let ids): copies = "copying \(ids.count) layer\(ids.count == 1 ? "" : "s")"
        case .everything: copies = "copying every layer"
        }
        DiagnosticsLog.shared.note(.undo, "step '\(description)' saved, \(copies)")
    }

    public func performUndo(renderer: CanvasRenderer) {
        guard let layerStack = layerStack else { return }
        undoManager.undo(layerStack: layerStack, viewModel: self, context: renderer.context)
        markDirty()
        renderer.updateAllThumbnails(in: layerStack)
        DiagnosticsLog.shared.note(.undo, "undo: \(undoManager.undoCount) steps left")
    }

    public func performRedo(renderer: CanvasRenderer) {
        guard let layerStack = layerStack else { return }
        undoManager.redo(layerStack: layerStack, viewModel: self, context: renderer.context)
        markDirty()
        renderer.updateAllThumbnails(in: layerStack)
        DiagnosticsLog.shared.note(.undo, "redo: \(undoManager.undoCount) steps")
    }

    // MARK: - Color

    public func toggleChrome() {
        isChromeHidden.toggle()
    }

    // MARK: - The view: zoom, rotation, flip, guides (the menus and the Adjust panel)

    public func zoomToFit(viewSize: CGSize) {
        transform.zoomToFit(canvasSize: canvasSize, viewSize: viewSize)
    }

    public func actualSize() {
        transform.scale = 1
        transform.offset = .zero
    }

    /// Turn to the next 15° mark in `direction` (+1 counter-clockwise) about the middle of
    /// the view, so repeated presses land on clean angles even after a freehand twist.
    public func rotateView(direction: CGFloat, viewSize: CGSize) {
        let step = CGFloat.pi / 12
        let marks = transform.rotation / step
        let next = direction > 0 ? (marks + 0.001).rounded(.down) + 1 : (marks - 0.001).rounded(.up) - 1
        transform.setRotation(next * step, at: Self.centre(of: viewSize), viewSize: viewSize)
    }

    public func resetRotation(viewSize: CGSize) {
        transform.setRotation(0, at: Self.centre(of: viewSize), viewSize: viewSize)
    }

    public func flipView(viewSize: CGSize) {
        transform.flip(at: Self.centre(of: viewSize), viewSize: viewSize)
    }

    /// The view as it starts: upright, unflipped, the canvas fitted to the window.
    public func resetView(viewSize: CGSize) {
        if transform.isFlipped { flipView(viewSize: viewSize) }
        resetRotation(viewSize: viewSize)
        zoomToFit(viewSize: viewSize)
    }

    public func changeGuides(_ change: (inout CanvasGuides) -> Void) {
        change(&guides)
        markDirty()
    }

    /// A new guide through the middle of the view, where the eye is.
    public func addGuide(horizontal: Bool, viewSize: CGSize) {
        let point = transform.viewToCanvas(Self.centre(of: viewSize), viewSize: viewSize)
        changeGuides {
            if horizontal { $0.horizontals.append(point.y.rounded()) } else { $0.verticals.append(point.x.rounded()) }
        }
    }

    private static func centre(of size: CGSize) -> CGPoint {
        CGPoint(x: size.width / 2, y: size.height / 2)
    }

    // MARK: - Selection

    public func selectAll() {
        selectionPath = CGPath(rect: CGRect(origin: .zero, size: canvasSize), transform: nil)
    }

    public func clearSelection() {
        selectionPath = nil
    }

    public func swapColors() {
        let temp = foregroundColor
        foregroundColor = swapBackgroundColor
        swapBackgroundColor = temp
        currentColor = foregroundColor
    }

    public func resetColors() {
        foregroundColor = .black
        swapBackgroundColor = .white
        currentColor = .black
    }
}
