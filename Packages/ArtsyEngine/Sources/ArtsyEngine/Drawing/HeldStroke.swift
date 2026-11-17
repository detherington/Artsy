import CoreGraphics
import Foundation

/// A stroke held to a drawing guide from where it lands until the pen lifts: along a
/// ruler, round an ellipse, or on a line of the perspective.
public enum HeldStroke {
    /// On whichever perspective line the pen's way chooses, once it has gone far enough.
    case perspective(PerspectiveStroke)
    /// Along a ruler's line, past its ends too.
    case ruler(RulerGuide)
    /// Round an ellipse, or round the one of its shape `scale` times its size.
    case ellipse(EllipseGuide, scale: CGFloat)

    /// What a stroke landing at `point` is held to with `guides` at `zoom` (screen points
    /// per canvas pixel), if anything:
    /// - a ruler or an ellipse whose edge it lands within reach of, the nearer;
    /// - else, with every size on, the ellipse of its shape through `point`;
    /// - else the perspective, if it holds strokes.
    public static func landing(at point: CGPoint, guides: CanvasGuides, zoom: CGFloat) -> HeldStroke? {
        let zoom = max(zoom, 0.01)
        let reach = DrawingGuide.strokeReach / zoom
        var nearest: (stroke: HeldStroke, distance: CGFloat)?
        if let ruler = guides.ruler, ruler.holdsStrokes {
            let d = ruler.distance(to: point)
            if d <= reach { nearest = (.ruler(ruler), d) }
        }
        if let ellipse = guides.ellipse, ellipse.holdsStrokes {
            let d = ellipse.distance(to: point)
            if d <= reach, d < (nearest?.distance ?? .infinity) { nearest = (.ellipse(ellipse, scale: 1), d) }
        }
        if let nearest { return nearest.stroke }
        if let ellipse = guides.ellipse, ellipse.holdsStrokes, ellipse.everySize {
            let scale = ellipse.scale(through: point)
            // One under a couple of screen points across is no ellipse to follow
            if scale * min(ellipse.radii.width, ellipse.radii.height) * zoom >= 2 {
                return .ellipse(ellipse, scale: scale)
            }
        }
        if let perspective = guides.perspective, perspective.holdsStrokes {
            return .perspective(PerspectiveStroke(guide: perspective, anchor: point, zoom: zoom))
        }
        return nil
    }

    /// Where a sample at `point` goes, the perspective choosing its line once the pen has
    /// gone far enough.
    public mutating func place(_ point: CGPoint) -> CGPoint {
        guard case .perspective(var stroke) = self else { return preview(point) }
        let placed = stroke.place(point)
        self = .perspective(stroke)
        return placed
    }

    /// Where a sample at `point` goes, choosing nothing: for a predicted touch, and for the
    /// first sample (the perspective keeps it where it landed).
    public func preview(_ point: CGPoint) -> CGPoint {
        switch self {
        case .perspective(let stroke): return stroke.preview(point)
        case .ruler(let ruler): return ruler.projected(point)
        case .ellipse(let ellipse, let scale): return ellipse.nearest(to: point, scale: scale)
        }
    }

    /// A sample after smoothing, put back on what holds it: smoothing a curve cuts inside
    /// it, though it keeps to a straight line.
    public func kept(_ point: CGPoint) -> CGPoint {
        guard case .ellipse(let ellipse, let scale) = self else { return point }
        return ellipse.nearest(to: point, scale: scale)
    }

    /// The perspective stroke, if that is what this is.
    public var perspective: PerspectiveStroke? {
        if case .perspective(let stroke) = self { return stroke }
        return nil
    }

    /// What holds it, for the diagnostics log; none for perspective until it has chosen.
    public var logName: String? {
        switch self {
        case .perspective(let stroke): return stroke.direction.map { "in perspective: \($0.logName)" }
        case .ruler: return "along the ruler"
        case .ellipse(_, let scale):
            return abs(scale - 1) < 1e-6 ? "round the ellipse" : String(format: "round the ellipse at %.2f×", scale)
        }
    }
}
