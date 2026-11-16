import CoreGraphics
import ArtsyEngine

/// How perspective guides are drawn over the canvas, the same on the Mac and on iPad:
/// each vanishing point's rays across the canvas in a colour of its own, faint, the
/// horizon in amber; while the points are being moved, the rays a little stronger, the
/// horizon reaching out to points off the canvas, and handles: a ring at each point and
/// a square at the horizon's middle, a few points across at any zoom.
enum PerspectiveStyle {
    /// Rays from each point across the canvas.
    static let rays = 18
    static let handleRadius: CGFloat = 9
    static let horizon = CGColor(srgbRed: 1, green: 0.72, blue: 0.15, alpha: 0.9)
    private static let hues: [(CGFloat, CGFloat, CGFloat)] = [(1, 0.32, 0.3), (0.25, 0.55, 1), (0.25, 0.78, 0.4)]

    /// Vanishing point `index`'s colour: its rays fainter than its handle.
    static func colour(_ index: Int, alpha: CGFloat = 1) -> CGColor {
        let (r, g, b) = hues[index % hues.count]
        return CGColor(srgbRed: r, green: g, blue: b, alpha: alpha)
    }

    static func rayAlpha(editing: Bool) -> CGFloat { editing ? 0.6 : 0.38 }

    /// What the horizon is drawn across: the canvas; while editing, out to the points too,
    /// so it can be seen joining points off the canvas.
    static func horizonRect(_ perspective: PerspectiveGuide, canvas: CGRect, editing: Bool) -> CGRect {
        guard editing else { return canvas }
        return perspective.points.reduce(canvas) { $0.union(CGRect(origin: $1, size: .zero)) }.insetBy(dx: -1, dy: -1)
    }

    /// The handles' shapes in view space: a circle at each point (in its own path, for its
    /// colour) and a square at the horizon's middle.
    static func handles(_ perspective: PerspectiveGuide, toView: CGAffineTransform) -> (points: [CGPath], horizon: CGPath?) {
        let r = handleRadius
        let points = perspective.points.map { p -> CGPath in
            let v = p.applying(toView)
            return CGPath(ellipseIn: CGRect(x: v.x - r, y: v.y - r, width: 2 * r, height: 2 * r), transform: nil)
        }
        let horizon = perspective.horizonHandle.map { p -> CGPath in
            let v = p.applying(toView), s = r * 0.8
            return CGPath(rect: CGRect(x: v.x - s, y: v.y - s, width: 2 * s, height: 2 * s), transform: nil)
        }
        return (points, horizon)
    }

    /// Segments in canvas space as one path in view space.
    static func path(_ segments: [(CGPoint, CGPoint)], toView: CGAffineTransform) -> CGPath {
        let path = CGMutablePath()
        for (a, b) in segments {
            path.move(to: a.applying(toView))
            path.addLine(to: b.applying(toView))
        }
        return path
    }
}
