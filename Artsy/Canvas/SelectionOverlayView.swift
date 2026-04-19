import AppKit

/// Transparent overlay that renders:
///   - Marching ants for the active selection
///   - Live preview for in-progress shapes (rectangle, ellipse, freeform)
/// Click-through so mouse events reach the CanvasView underneath.
class SelectionOverlayView: NSView {
    weak var viewModel: CanvasViewModel?
    private var animationTimer: Timer?
    private var dashPhase: CGFloat = 0

    override var isOpaque: Bool { false }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    func startAnimation() {
        animationTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            self.dashPhase += 0.5
            if self.dashPhase > 100 { self.dashPhase = 0 }
            self.needsDisplay = true
        }
    }

    deinit {
        animationTimer?.invalidate()
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let vm = viewModel else { return }

        // Shared canvas → view transform
        let cx = bounds.width / 2 + vm.transform.offset.x
        let cy = bounds.height / 2 + vm.transform.offset.y
        var transform = CGAffineTransform.identity
        transform = transform.translatedBy(x: cx, y: cy)
        transform = transform.scaledBy(x: vm.transform.scale, y: vm.transform.scale)

        // Draw symmetry guide lines (subtle dashed lines across the canvas center)
        if vm.symmetryMode.isOn {
            drawSymmetryGuides(for: vm, transform: transform)
        }

        // Draw transform handles if a transform session is active
        if let session = vm.transformSession {
            drawTransformHandles(session: session, transform: transform)
        }

        // Draw shape preview (solid stroke/fill, no marching ants)
        if let shapePath = vm.previewShapePath,
           let viewPath = shapePath.copy(using: &transform) {
            let bezier = NSBezierPath(cgPath: viewPath)

            if vm.shapeFillEnabled {
                vm.swapBackgroundColor.nsColor.setFill()
                bezier.fill()
            }
            if vm.shapeStrokeEnabled {
                bezier.lineWidth = max(1.0, vm.shapeStrokeWidth * vm.transform.scale)
                vm.currentColor.nsColor.setStroke()
                bezier.stroke()
            }
        }

        // Draw selection marquee (marching ants)
        if let selectionPath = vm.selectionPath,
           let viewPath = selectionPath.copy(using: &transform) {
            let bezier = NSBezierPath(cgPath: viewPath)
            bezier.lineWidth = 1.0
            NSColor.white.setStroke()
            bezier.stroke()

            let pattern: [CGFloat] = [5, 4]
            bezier.setLineDash(pattern, count: 2, phase: dashPhase)
            bezier.lineWidth = 1.0
            NSColor.black.setStroke()
            bezier.stroke()
        }
    }

    /// Draw subtle guide lines showing the symmetry axes. Canvas coords are Y-up
    /// [0, W] × [0, H]; we build the paths in canvas space then transform them
    /// into view space. Guides are clipped to the canvas rectangle so radial
    /// spokes don't bleed past the canvas edges.
    private func drawSymmetryGuides(for vm: CanvasViewModel, transform: CGAffineTransform) {
        let W = vm.canvasSize.width
        let H = vm.canvasSize.height
        let cx = W / 2
        let cy = H / 2

        // Build all guide segments in canvas space first.
        var segments: [(CGPoint, CGPoint)] = []

        switch vm.symmetryMode {
        case .off:
            return

        case .horizontal:
            segments.append((CGPoint(x: cx, y: 0), CGPoint(x: cx, y: H)))

        case .vertical:
            segments.append((CGPoint(x: 0, y: cy), CGPoint(x: W, y: cy)))

        case .quad:
            segments.append((CGPoint(x: cx, y: 0), CGPoint(x: cx, y: H)))
            segments.append((CGPoint(x: 0, y: cy), CGPoint(x: W, y: cy)))

        case .radial(let n):
            // Extend each spoke past the canvas corners, then clip to canvas rect below.
            let reach = sqrt(W * W + H * H)  // more than enough to cover canvas
            for k in 0..<max(2, n) {
                let angle = (CGFloat(k) * .pi) / CGFloat(max(2, n))
                let dx = reach * cos(angle)
                let dy = reach * sin(angle)
                segments.append((
                    CGPoint(x: cx - dx, y: cy - dy),
                    CGPoint(x: cx + dx, y: cy + dy)
                ))
            }
        }

        // Clip every segment to the canvas rectangle [0,W]×[0,H]
        let canvasRect = CGRect(x: 0, y: 0, width: W, height: H)
        let path = NSBezierPath()
        for (a, b) in segments {
            if let (ca, cb) = liangBarskyClip(a: a, b: b, rect: canvasRect) {
                path.move(to: ca.applying(transform))
                path.line(to: cb.applying(transform))
            }
        }

        path.lineWidth = 1.0
        let dashes: [CGFloat] = [6, 4]
        path.setLineDash(dashes, count: 2, phase: 0)
        NSColor(calibratedWhite: 1.0, alpha: 0.25).setStroke()
        path.stroke()
    }

    /// Draw the transform bounding box + scale corner handles + rotation stem.
    /// Lines use a two-pass render (solid black, then dashed white on top) so
    /// they're visible against both light and dark canvases.
    private func drawTransformHandles(session: TransformSession, transform: CGAffineTransform) {
        let corners = session.transformedCorners  // [TL, TR, BR, BL] (canvas Y-up)
        let viewCorners = corners.map { $0.applying(transform) }

        // Bounding polygon
        let polygon = NSBezierPath()
        polygon.move(to: viewCorners[0])
        polygon.line(to: viewCorners[1])
        polygon.line(to: viewCorners[2])
        polygon.line(to: viewCorners[3])
        polygon.close()

        // Rotation stem
        let topCenter = CGPoint(
            x: (corners[0].x + corners[1].x) / 2,
            y: (corners[0].y + corners[1].y) / 2
        )
        let center = session.transformedCenter
        let dx = topCenter.x - center.x
        let dy = topCenter.y - center.y
        let len = max(sqrt(dx * dx + dy * dy), 0.001)
        let extend: CGFloat = 28 / max(0.001, currentScale)
        let rotHandleCanvas = CGPoint(
            x: topCenter.x + (dx / len) * extend,
            y: topCenter.y + (dy / len) * extend
        )
        let rotHandleView = rotHandleCanvas.applying(transform)
        let topCenterView = topCenter.applying(transform)

        let rotStem = NSBezierPath()
        rotStem.move(to: topCenterView)
        rotStem.line(to: rotHandleView)

        // Pass 1: solid black underlay on everything.
        NSColor(calibratedWhite: 0.0, alpha: 0.75).setStroke()
        polygon.lineWidth = 1.5
        polygon.stroke()
        rotStem.lineWidth = 1.5
        rotStem.stroke()

        // Pass 2: dashed white on top, slightly thinner, for contrast on dark canvases.
        polygon.lineWidth = 1.0
        rotStem.lineWidth = 1.0
        let dashes: [CGFloat] = [5, 3]
        polygon.setLineDash(dashes, count: 2, phase: 0)
        rotStem.setLineDash(dashes, count: 2, phase: 0)
        NSColor(calibratedWhite: 1.0, alpha: 1.0).setStroke()
        polygon.stroke()
        rotStem.stroke()

        // Draw handle knobs (filled white with blue accent stroke)
        NSColor(calibratedWhite: 1.0, alpha: 1.0).setFill()
        NSColor(calibratedRed: 0.12, green: 0.4, blue: 1.0, alpha: 1.0).setStroke()

        for c in viewCorners {
            drawHandleSquare(at: c, size: 9)
        }
        drawHandleCircle(at: rotHandleView, size: 10)
    }

    /// The current canvas→view scale, used to keep handle sizes constant at any zoom.
    private var currentScale: CGFloat {
        viewModel?.transform.scale ?? 1.0
    }

    private func drawHandleSquare(at p: CGPoint, size: CGFloat) {
        let r = CGRect(x: p.x - size / 2, y: p.y - size / 2, width: size, height: size)
        let path = NSBezierPath(rect: r)
        path.fill()
        path.lineWidth = 1.5
        path.stroke()
    }

    private func drawHandleCircle(at p: CGPoint, size: CGFloat) {
        let r = CGRect(x: p.x - size / 2, y: p.y - size / 2, width: size, height: size)
        let path = NSBezierPath(ovalIn: r)
        path.fill()
        path.lineWidth = 1.5
        path.stroke()
    }

    /// Liang–Barsky line clipping against an axis-aligned rect.
    /// Returns the clipped endpoints, or nil if the segment lies entirely outside.
    private func liangBarskyClip(
        a: CGPoint, b: CGPoint, rect: CGRect
    ) -> (CGPoint, CGPoint)? {
        let dx = b.x - a.x
        let dy = b.y - a.y
        var t0: CGFloat = 0
        var t1: CGFloat = 1

        let ps: [CGFloat] = [-dx, dx, -dy, dy]
        let qs: [CGFloat] = [a.x - rect.minX, rect.maxX - a.x, a.y - rect.minY, rect.maxY - a.y]

        for i in 0..<4 {
            let p = ps[i]
            let q = qs[i]
            if p == 0 {
                if q < 0 { return nil }         // parallel and outside
            } else {
                let r = q / p
                if p < 0 {
                    if r > t1 { return nil }
                    if r > t0 { t0 = r }
                } else {
                    if r < t0 { return nil }
                    if r < t1 { t1 = r }
                }
            }
        }
        return (
            CGPoint(x: a.x + t0 * dx, y: a.y + t0 * dy),
            CGPoint(x: a.x + t1 * dx, y: a.y + t1 * dy)
        )
    }
}
