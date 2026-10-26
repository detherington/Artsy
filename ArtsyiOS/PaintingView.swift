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
/// Pencil and a finger give none, and the engine derives one from speed.
final class PaintingView: MTKView {
    private weak var viewModel: CanvasViewModel?
    private weak var renderer: CanvasRenderer?
    /// The touch drawing the stroke in progress, if any.
    private var drawingTouch: UITouch?
    private var strokeHasPressure = false
    /// Whether a finger draws; two fingers always pan, pinch and turn.
    var fingerPaints = true

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

    // MARK: - Strokes

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard drawingTouch == nil, let viewModel, let renderer,
              let touch = touches.first(where: { $0.type == .pencil }) ?? (fingerPaints ? touches.first(where: { $0.type == .direct }) : nil)
        else { return }
        // Two fingers at once are a gesture, not a stroke
        if touch.type == .direct, event?.allTouches?.filter({ $0.type == .direct }).count ?? 1 > 1 { return }
        drawingTouch = touch
        strokeHasPressure = touch.type == .pencil && touch.force > 0
        renderer.beginStroke()
        viewModel.beginStroke(point: strokePoint(from: touch), hasPressure: strokeHasPressure)
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard let touch = drawingTouch, touches.contains(touch), let viewModel else { return }
        // Every sample the Pencil made since the last event, not only the last one
        for sample in event?.coalescedTouches(for: touch) ?? [touch] {
            viewModel.continueStroke(point: strokePoint(from: sample))
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
    /// as the two tilt components, its roll (a Pencil Pro) as rotation.
    private func strokePoint(from touch: UITouch) -> StrokePoint {
        guard let viewModel else { return StrokePoint(position: .zero, pressure: 0, tiltX: 0, tiltY: 0, rotation: 0, timestamp: touch.timestamp) }
        let location = touch.location(in: self)
        let upwards = CGPoint(x: location.x, y: bounds.height - location.y)
        let canvas = viewModel.transform.viewToCanvas(upwards, viewSize: bounds.size)
        let pressure: Float = touch.type == .pencil && touch.maximumPossibleForce > 0
            ? Float(min(max(touch.force / touch.maximumPossibleForce, 0), 1)) : 0.7
        var tilt: (x: Float, y: Float) = (0, 0)
        if touch.type == .pencil {
            tilt = PencilTilt.tilt(altitude: touch.altitudeAngle, azimuth: touch.azimuthAngle(in: self))
        }
        var rotation: Float = 0
        if #available(iOS 17.5, *), touch.type == .pencil { rotation = Float(touch.rollAngle * 180 / .pi) }
        return StrokePoint(position: canvas, pressure: pressure, tiltX: tilt.x, tiltY: tilt.y, rotation: rotation, timestamp: touch.timestamp)
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

/// The painting view for SwiftUI.
struct CanvasHost: UIViewRepresentable {
    let context: MetalContext
    let viewModel: CanvasViewModel
    let renderer: CanvasRenderer

    func makeUIView(context: Context) -> PaintingView {
        PaintingView(frame: .zero, context: self.context, viewModel: viewModel, renderer: renderer)
    }

    func updateUIView(_ view: PaintingView, context: Context) {}
}
