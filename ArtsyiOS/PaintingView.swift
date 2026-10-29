import UIKit
import MetalKit
import SwiftUI
import ArtsyEngine

/// The canvas on iPad and iPhone: the engine's renderer drawing into a Metal view, the
/// Pencil (or a finger) drawing strokes, two fingers panning, pinching and turning the
/// canvas.
///
/// Touch points are handed to the engine in the Mac's view space, y up, so the one
/// transform serves both platforms; the picture itself needs no flip, since a Metal
/// drawable's y runs the same way on both. A Pencil with pressure gives it; the USB-C
/// Pencil and a finger give none, and the engine derives one from speed. Which a Pencil
/// is cannot be read off its landing sample alone, whose force is an estimate that may
/// read zero: see `strokeHasPressure(beginning:)`.
final class PaintingView: MTKView {
    private weak var viewModel: CanvasViewModel?
    private(set) weak var renderer: CanvasRenderer?
    /// The touch drawing the stroke in progress, if any.
    private var drawingTouch: UITouch?
    private var strokeHasPressure = false
    /// Whether the Pencil in use has ever reported a force. Once it has, every stroke
    /// starts with pressure even when its landing sample reads zero, which a Pencil's
    /// first, estimated force can. Session-wide: the Pencil does not change mid-document.
    private static var pencilHasReportedForce = false
    /// Whether a finger draws; two fingers always pan, pinch and turn.
    var fingerPaints = true

    /// The width the canvas was last fitted or laid out at, to tell a fold or a turn from
    /// the chrome coming and going.
    private var lastLayoutWidth: CGFloat = 0
    private var lastPinchScale: CGFloat = 1
    private var lastRotation: CGFloat = 0
    private var lastPan: CGPoint = .zero

    init(frame: CGRect, context: MetalContext, viewModel: CanvasViewModel, renderer: CanvasRenderer) {
        super.init(frame: frame, device: context.device)
        self.viewModel = viewModel
        self.renderer = renderer
        colorPixelFormat = .bgra8Unorm
        // Display P3, as on the Mac: the view has no colorspace of its own on iOS, its layer has
        (layer as? CAMetalLayer)?.colorspace = CGColorSpace(name: CGColorSpace.displayP3)
        preferredFramesPerSecond = 120
        isPaused = false
        enableSetNeedsDisplay = false
        clearColor = MTLClearColor(red: 0.18, green: 0.18, blue: 0.18, alpha: 1)
        isMultipleTouchEnabled = true
        delegate = renderer

        let pinch = UIPinchGestureRecognizer(target: self, action: #selector(pinched(_:)))
        let rotate = UIRotationGestureRecognizer(target: self, action: #selector(rotated(_:)))
        let pan = UIPanGestureRecognizer(target: self, action: #selector(panned(_:)))
        pan.minimumNumberOfTouches = 2
        pan.maximumNumberOfTouches = 2
        for gesture in [pinch, rotate, pan] as [UIGestureRecognizer] {
            // Fingers only: the Pencil draws
            gesture.allowedTouchTypes = [UITouch.TouchType.direct.rawValue as NSNumber]
            gesture.delegate = self
            addGestureRecognizer(gesture)
        }
    }

    required init(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// A fold, an unfold or a turn changes the width by a quarter or more: the canvas is
    /// fitted again. The rail and bar coming and going change it less, and keep the view.
    override func layoutSubviews() {
        super.layoutSubviews()
        let width = bounds.width
        guard width > 0 else { return }
        if lastLayoutWidth > 0, abs(width - lastLayoutWidth) / lastLayoutWidth >= 0.25 {
            viewModel?.zoomToFit(viewSize: bounds.size)
        }
        lastLayoutWidth = width
    }

    // MARK: - Strokes

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard drawingTouch == nil, let viewModel, let renderer,
              let touch = touches.first(where: { $0.type == .pencil }) ?? (fingerPaints ? touches.first(where: { $0.type == .direct }) : nil)
        else { return }
        // Two fingers at once are a gesture, not a stroke
        if touch.type == .direct, event?.allTouches?.filter({ $0.type == .direct }).count ?? 1 > 1 { return }
        switch viewModel.currentTool {
        case .brush, .eraser:
            drawingTouch = touch
            strokeHasPressure = strokeHasPressure(beginning: touch)
            renderer.beginStroke()
            viewModel.beginStroke(point: strokePoint(from: touch),
                                  input: strokeHasPressure ? .pen : (touch.type == .pencil ? .penWithoutPressure : .hand))
        case .eyedropper:
            pickColor(at: canvasPoint(of: touch))
        case .fill:
            fill(at: canvasPoint(of: touch))
        default:
            // Selection, shapes and transforms are not on iPad yet
            break
        }
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard let touch = drawingTouch, touches.contains(touch), let viewModel else { return }
        // Every sample the Pencil made since the last event, not only the last one
        for sample in event?.coalescedTouches(for: touch) ?? [touch] {
            noteForce(of: sample)
            viewModel.continueStroke(point: strokePoint(from: sample))
        }
        // And where UIKit expects it to be next: drawn in the tail this frame, and gone
        // when the real samples come, so the stroke shows a frame closer to the pen
        viewModel.predictStroke((event?.predictedTouches(for: touch) ?? []).map(strokePoint(from:)))
    }

    /// The Pencil's real force, arriving after the estimate: too late for the samples
    /// already drawn, but enough to tell a Pencil with a force sensor from one without.
    override func touchesEstimatedPropertiesUpdated(_ touches: Set<UITouch>) {
        guard let touch = drawingTouch, touches.contains(touch) else { return }
        noteForce(of: touch)
    }

    /// Whether a stroke beginning with `touch` has pressure of its own. A finger never
    /// does. A Pencil's force is estimated at first and refined later, so its landing
    /// sample can read zero even on a Pencil with a force sensor (the first and second
    /// generations, the Pro): the stroke has pressure if the sample reads a force, if an
    /// update to it is expected, or if this Pencil has reported force before. The USB-C
    /// Pencil has no sensor: it reads zero and expects no update, so its strokes take
    /// their pressure from speed. A stroke that starts without pressure and then reports
    /// some switches to it (`noteForce`).
    private func strokeHasPressure(beginning touch: UITouch) -> Bool {
        guard touch.type == .pencil else { return false }
        if touch.force > 0 {
            Self.pencilHasReportedForce = true
            return true
        }
        return Self.pencilHasReportedForce || touch.estimatedPropertiesExpectingUpdates.contains(.force)
    }

    /// A Pencil sample's force, into the record: a stroke that began without pressure
    /// takes the Pencil's own from here on.
    private func noteForce(of touch: UITouch) {
        guard touch.type == .pencil, touch.force > 0 else { return }
        if !Self.pencilHasReportedForce {
            Self.pencilHasReportedForce = true
            DiagnosticsLog.shared.note(.stroke, "the Pencil reports force")
        }
        if !strokeHasPressure, drawingTouch != nil {
            strokeHasPressure = true
            viewModel?.strokeReportsPressure()
            DiagnosticsLog.shared.note(.stroke, "the stroke began without pressure and the Pencil's force arrived: its own pressure from here")
        }
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard let touch = drawingTouch, touches.contains(touch) else { return }
        endStroke(with: touch)
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard let touch = drawingTouch, touches.contains(touch) else { return }
        endStroke(with: touch)
    }

    private func endStroke(with touch: UITouch) {
        drawingTouch = nil
        guard let viewModel, let renderer else { return }
        if let summary = viewModel.strokeSummary() {
            DiagnosticsLog.shared.note(.stroke, summary + (touch.type == .pencil ? ", pencil" : ", finger"))
        }
        // Finalize first: the renderer still needs the stroke's points to draw its last samples
        renderer.finalizeStroke()
        viewModel.endStroke()
    }

    /// A touch as a stroke sample in canvas space: its point in the engine's y-up view
    /// space through the canvas transform, its force as pressure, its altitude and azimuth
    /// as the two tilt components, its roll (a Pencil Pro) as rotation. A finger, or a
    /// Pencil without a force sensor, gets a constant the view model may replace from speed.
    private func strokePoint(from touch: UITouch) -> StrokePoint {
        guard viewModel != nil else { return StrokePoint(position: .zero, pressure: 0, tiltX: 0, tiltY: 0, rotation: 0, timestamp: touch.timestamp) }
        let canvas = canvasPoint(of: touch)
        let pressure: Float = touch.type == .pencil && strokeHasPressure && touch.maximumPossibleForce > 0
            ? Float(min(max(touch.force / touch.maximumPossibleForce, 0), 1)) : 0.7
        var tilt: (x: Float, y: Float) = (0, 0)
        if touch.type == .pencil {
            tilt = PencilTilt.tilt(altitude: touch.altitudeAngle, azimuth: touch.azimuthAngle(in: self))
        }
        var rotation: Float = 0
        if #available(iOS 17.5, *), touch.type == .pencil { rotation = Float(touch.rollAngle * 180 / .pi) }
        return StrokePoint(position: canvas, pressure: pressure, tiltX: tilt.x, tiltY: tilt.y, rotation: rotation, timestamp: touch.timestamp)
    }

    /// A touch's point on the canvas, through the transform from the engine's y-up view space.
    private func canvasPoint(of touch: UITouch) -> CGPoint {
        guard let viewModel else { return .zero }
        return viewModel.transform.viewToCanvas(upwards(touch.location(in: self)), viewSize: bounds.size)
    }

    // MARK: - Eyedropper and fill

    /// The colour under the touch, as displayed: the composite over the white that shows
    /// through wherever the canvas is not opaque. Then back to the brush, as on the Mac.
    private func pickColor(at canvasPoint: CGPoint) {
        guard let viewModel, let renderer, let composite = renderer.compositeTexture else { return }
        let size = viewModel.canvasSize
        guard canvasPoint.x >= 0, canvasPoint.x < size.width, canvasPoint.y >= 0, canvasPoint.y < size.height else { return }
        // Canvas coordinates (y up) to the texture's (y down)
        let tx = Int(canvasPoint.x.rounded()), ty = Int((size.height - canvasPoint.y).rounded())
        guard tx >= 0, tx < composite.width, ty >= 0, ty < composite.height,
              let staging = try? renderer.textureManager.makeSharedTexture(width: 1, height: 1, label: "Eyedropper"),
              let commands = renderer.context.commandQueue.makeCommandBuffer(),
              let blit = commands.makeBlitCommandEncoder() else { return }
        blit.copy(from: composite, sourceSlice: 0, sourceLevel: 0, sourceOrigin: MTLOrigin(x: tx, y: ty, z: 0),
                  sourceSize: MTLSize(width: 1, height: 1, depth: 1),
                  to: staging, destinationSlice: 0, destinationLevel: 0, destinationOrigin: MTLOrigin(x: 0, y: 0, z: 0))
        blit.endEncoding()
        commands.commit()
        commands.waitUntilCompleted()
        var half: [UInt16] = [0, 0, 0, 0]
        half.withUnsafeMutableBytes { raw in
            staging.getBytes(raw.baseAddress!, bytesPerRow: 8,
                             from: MTLRegion(origin: MTLOrigin(x: 0, y: 0, z: 0), size: MTLSize(width: 1, height: 1, depth: 1)), mipmapLevel: 0)
        }
        let through = 1 - Float(Float16(bitPattern: half[3]))
        let picked = StrokeColor(red: min(1, max(0, Float(Float16(bitPattern: half[0])) + through)),
                                 green: min(1, max(0, Float(Float16(bitPattern: half[1])) + through)),
                                 blue: min(1, max(0, Float(Float16(bitPattern: half[2])) + through)), alpha: 1)
        viewModel.foregroundColor = picked
        viewModel.currentColor = picked
        viewModel.currentTool = .brush
    }

    /// A bucket fill from the touch, as on the Mac: the undo step saved first, the fill
    /// in the background, applied only if the step still stands when it lands.
    private func fill(at canvasPoint: CGPoint) {
        guard let viewModel, let renderer, let layer = viewModel.layerStack?.activeLayer, !layer.isLocked else { return }
        let size = viewModel.canvasSize
        guard canvasPoint.x >= 0, canvasPoint.x < size.width, canvasPoint.y >= 0, canvasPoint.y < size.height else { return }
        viewModel.saveUndoSnapshot(renderer: renderer, description: "Fill", changing: .layer(layer))
        let step = viewModel.undoManager.lastStepToken
        let started = DispatchTime.now().uptimeNanoseconds
        BucketFill.fillAsync(
            renderer: renderer, layer: layer, canvasPoint: canvasPoint, canvasSize: size,
            fillColor: viewModel.currentColor, tolerance: viewModel.fillTolerance, selectionPath: viewModel.selectionPath,
            shouldApply: { [weak viewModel, weak layer] in
                guard let viewModel, let layer, viewModel.undoManager.holds(step),
                      viewModel.layerStack?.layers.contains(where: { $0 === layer }) == true else { return false }
                return true
            }
        ) { [weak renderer, weak layer] in
            guard let renderer, let layer else { return }
            DiagnosticsLog.shared.note(.tool, String(format: "fill landed after %.2f s", Double(DispatchTime.now().uptimeNanoseconds - started) / 1e9))
            renderer.updateThumbnail(for: layer)
            renderer.viewModel?.noteContentChanged()
        }
    }

    // MARK: - Two fingers: pan, pinch, turn

    /// A gesture's location in the engine's y-up view space.
    private func upwards(_ location: CGPoint) -> CGPoint {
        CGPoint(x: location.x, y: bounds.height - location.y)
    }

    @objc private func pinched(_ gesture: UIPinchGestureRecognizer) {
        guard let viewModel else { return }
        if gesture.state == .began { lastPinchScale = 1 }
        guard gesture.state == .changed, lastPinchScale > 0 else { return }
        viewModel.transform.zoom(by: gesture.scale / lastPinchScale, at: upwards(gesture.location(in: self)), viewSize: bounds.size)
        lastPinchScale = gesture.scale
    }

    @objc private func rotated(_ gesture: UIRotationGestureRecognizer) {
        guard let viewModel else { return }
        if gesture.state == .began { lastRotation = 0 }
        guard gesture.state == .changed else { return }
        // UIKit's rotation is clockwise-positive on a y-down screen; the engine's is counter-clockwise
        viewModel.transform.rotate(by: -(gesture.rotation - lastRotation), at: upwards(gesture.location(in: self)), viewSize: bounds.size)
        lastRotation = gesture.rotation
    }

    @objc private func panned(_ gesture: UIPanGestureRecognizer) {
        guard let viewModel else { return }
        if gesture.state == .began { lastPan = .zero }
        guard gesture.state == .changed else { return }
        let translation = gesture.translation(in: self)
        viewModel.transform.pan(by: CGPoint(x: translation.x - lastPan.x, y: -(translation.y - lastPan.y)))
        lastPan = translation
    }
}

extension PaintingView: UIGestureRecognizerDelegate {
    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                           shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool { true }
}

/// The session's painting view, for SwiftUI.
struct CanvasHost: UIViewRepresentable {
    let view: PaintingView

    func makeUIView(context: Context) -> PaintingView { view }

    func updateUIView(_ view: PaintingView, context: Context) {}
}
