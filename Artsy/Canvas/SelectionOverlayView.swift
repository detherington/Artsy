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
}
