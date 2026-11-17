import CoreGraphics
import ArtsyEngine

/// How the ruler and the ellipse template are drawn over the canvas, the same on the Mac
/// and on iPad: violet lines, the ruler with a short tick across each end; with every size
/// on, two more sizes of the ellipse, fainter; while one is being moved, its handles (rings
/// at the ruler's ends and on the ellipse's axes, a square for moving the whole guide) and
/// the ellipse's axes, faint. Both platforms draw the same marks, in order.
enum RulerStyle {
    /// One thing to draw: a path in view space, filled if it has a fill, then stroked if it
    /// has a stroke, dashed if it has a dash.
    struct Mark {
        let path: CGPath
        let stroke: CGColor?
        var width: CGFloat = 1
        var fill: CGColor? = nil
        var dash: [CGFloat]? = nil
        /// What it is kept inside, in view space, if anything.
        var clip: CGPath? = nil
    }

    static func colour(alpha: CGFloat = 1) -> CGColor {
        CGColor(srgbRed: 0.62, green: 0.38, blue: 1, alpha: alpha)
    }

    static func lineAlpha(editing: Bool) -> CGFloat { editing ? 0.9 : 0.65 }
    static let lineWidth: CGFloat = 1.5
    /// The other sizes drawn with every size on, as multiples of the ellipse.
    static let otherSizes: [CGFloat] = [0.5, 1.5]
    /// Half the length of the tick across each end of the ruler, in points.
    static let tick: CGFloat = 5

    /// What to draw for `ruler` and `ellipse`, each if it is shown, with the handles of the
    /// one being edited, in view space.
    static func marks(ruler: RulerGuide?, ellipse: EllipseGuide?, editing: DrawingGuide?,
                      toView: CGAffineTransform) -> [Mark] {
        var marks: [Mark] = []
        let white = CGColor(gray: 1, alpha: 1)
        if let ruler, ruler.isShown {
            let edited = editing == .ruler
            let a = ruler.start.applying(toView), b = ruler.end.applying(toView)
            let line = CGMutablePath()
            line.move(to: a)
            line.addLine(to: b)
            let length = hypot(b.x - a.x, b.y - a.y)
            if length > 1e-6 {
                // A tick square across each end, so its ends show
                let n = CGVector(dx: -(b.y - a.y) / length * tick, dy: (b.x - a.x) / length * tick)
                for p in [a, b] {
                    line.move(to: CGPoint(x: p.x - n.dx, y: p.y - n.dy))
                    line.addLine(to: CGPoint(x: p.x + n.dx, y: p.y + n.dy))
                }
            }
            marks.append(Mark(path: line, stroke: colour(alpha: lineAlpha(editing: edited)), width: lineWidth))
            if edited {
                marks += handles(rings: [ruler.start, ruler.end], square: ruler.middle, toView: toView, fill: white)
            }
        }
        if let ellipse, ellipse.isShown {
            let edited = editing == .ellipse
            if ellipse.everySize {
                for scale in otherSizes {
                    marks.append(Mark(path: outline(ellipse, scale: scale, toView: toView), stroke: colour(alpha: 0.3), width: 1))
                }
            }
            marks.append(Mark(path: outline(ellipse, toView: toView), stroke: colour(alpha: lineAlpha(editing: edited)), width: lineWidth))
            if edited {
                marks.append(Mark(path: PerspectiveStyle.path(ellipse.axes, toView: toView), stroke: colour(alpha: 0.35), width: 1))
                marks += handles(rings: [ellipse.position(of: .axis), ellipse.position(of: .across)],
                                 square: ellipse.centre, toView: toView, fill: white)
            }
        }
        return marks
    }

    /// The ellipse's outline at `scale` times its size, in view space.
    static func outline(_ ellipse: EllipseGuide, scale: CGFloat = 1, toView: CGAffineTransform) -> CGPath {
        var transform = ellipse.placement.concatenating(toView)
        let a = ellipse.radii.width * scale, b = ellipse.radii.height * scale
        return CGPath(ellipseIn: CGRect(x: -a, y: -b, width: 2 * a, height: 2 * b), transform: &transform)
    }

    /// Rings at `rings` and a square at `square`, a few points across at any zoom, as the
    /// perspective's handles are.
    static func handles(rings: [CGPoint], square: CGPoint, toView: CGAffineTransform, fill: CGColor) -> [Mark] {
        let r = PerspectiveStyle.handleRadius
        var marks = rings.map { p -> Mark in
            let v = p.applying(toView)
            return Mark(path: CGPath(ellipseIn: CGRect(x: v.x - r, y: v.y - r, width: 2 * r, height: 2 * r), transform: nil),
                        stroke: colour(), width: 2, fill: fill)
        }
        let v = square.applying(toView), s = r * 0.8
        marks.append(Mark(path: CGPath(rect: CGRect(x: v.x - s, y: v.y - s, width: 2 * s, height: 2 * s), transform: nil),
                          stroke: colour(), width: 2, fill: fill))
        return marks
    }
}
