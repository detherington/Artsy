import CoreGraphics
import Foundation

/// A drawn glyph's ink as outlines. A stroke covers, between each point and the next, the
/// convex hull of the pen's shape at both (a disc for the round pens, a thin bar across the
/// chisel's nib), so its width follows the pressure and its turns are round. The pieces are
/// all wound one way: filled as they are (the Font Studio's pad), overlaps add up; merged
/// (`contours`), they are the clean outlines a font is made of.
public enum GlyphOutline {
    /// Every piece of every stroke of `glyph`, in font units.
    public static func path(of glyph: DrawnGlyph) -> CGPath {
        let path = CGMutablePath()
        for stroke in glyph.strokes { addPieces(of: stroke, to: path) }
        return path
    }

    /// The pieces of one stroke.
    public static func path(of stroke: GlyphStroke) -> CGPath {
        let path = CGMutablePath()
        addPieces(of: stroke, to: path)
        return path
    }

    /// Adds the pieces of `stroke` from its `start`th point on: the dot of a stroke of one
    /// point, else the piece from each point to the one before. A stroke growing as it is
    /// drawn adds only what its new points cover.
    public static func addPieces(of stroke: GlyphStroke, from start: Int = 0, to path: CGMutablePath) {
        let count = stroke.points.count
        guard count > 0 else { return }
        func add(_ polygon: [CGPoint]) {
            guard polygon.count > 2 else { return }
            path.addLines(between: polygon)
            path.closeSubpath()
        }
        if count == 1 {
            if start == 0 { add(hull(shape(of: stroke, at: 0))) }
            return
        }
        let first = max(1, start)
        guard first < count else { return }
        var previous = shape(of: stroke, at: first - 1)
        for i in first..<count {
            let current = shape(of: stroke, at: i)
            add(hull(previous + current))
            previous = current
        }
    }

    /// The pen's shape at the stroke's `index`th point: a polygon round enough for its size,
    /// or the chisel's bar.
    static func shape(of stroke: GlyphStroke, at index: Int) -> [CGPoint] {
        let p = stroke.points[index]
        let width = max(1, stroke.width(at: index))
        switch stroke.pen {
        case .chisel:
            let along = CGPoint(x: cos(GlyphPen.nibAngle) * width / 2, y: sin(GlyphPen.nibAngle) * width / 2)
            let across = CGPoint(x: -along.y * GlyphPen.nibThickness, y: along.x * GlyphPen.nibThickness)
            return [CGPoint(x: p.x - along.x - across.x, y: p.y - along.y - across.y),
                    CGPoint(x: p.x + along.x - across.x, y: p.y + along.y - across.y),
                    CGPoint(x: p.x + along.x + across.x, y: p.y + along.y + across.y),
                    CGPoint(x: p.x - along.x + across.x, y: p.y - along.y + across.y)]
        case .marker, .brush:
            let radius = width / 2
            // Sides enough that a side strays less than about a unit from the circle
            let sides = min(32, max(10, Int((CGFloat.pi / acos(max(0.5, 1 - 0.8 / radius))).rounded(.up))))
            return (0..<sides).map { k in
                let a = CGFloat(k) / CGFloat(sides) * 2 * .pi
                return CGPoint(x: p.x + radius * cos(a), y: p.y + radius * sin(a))
            }
        }
    }

    /// The convex hull of `points`, anticlockwise with y up (Andrew's monotone chain).
    static func hull(_ points: [CGPoint]) -> [CGPoint] {
        let sorted = points.sorted { $0.x != $1.x ? $0.x < $1.x : $0.y < $1.y }
        guard sorted.count > 2 else { return sorted }
        func cross(_ o: CGPoint, _ a: CGPoint, _ b: CGPoint) -> CGFloat {
            (a.x - o.x) * (b.y - o.y) - (a.y - o.y) * (b.x - o.x)
        }
        var lower: [CGPoint] = []
        for p in sorted {
            while lower.count >= 2, cross(lower[lower.count - 2], lower[lower.count - 1], p) <= 0 { lower.removeLast() }
            lower.append(p)
        }
        var upper: [CGPoint] = []
        for p in sorted.reversed() {
            while upper.count >= 2, cross(upper[upper.count - 2], upper[upper.count - 1], p) <= 0 { upper.removeLast() }
            upper.append(p)
        }
        return Array(lower.dropLast() + upper.dropLast())
    }

    // MARK: - Clean outlines

    /// A contour of a font's glyph: points on the outline in font units, all on the curve.
    public typealias Contour = [(x: Int, y: Int)]

    /// The glyph's ink as a font wants it: the pieces' union, flattened, simplified to within
    /// `tolerance` font units, rounded to whole units, outlines clockwise and the holes in
    /// them anticlockwise (TrueType fills by winding). Empty for a glyph with no ink.
    public static func contours(of glyph: DrawnGlyph, tolerance: CGFloat = 1.2) -> [Contour] {
        let pieces = path(of: glyph)
        guard !pieces.isEmpty else { return [] }
        var contours: [[CGPoint]] = []
        var current: [CGPoint] = []
        pieces.normalized(using: .winding).flattened(threshold: 0.5).applyWithBlock { element in
            let e = element.pointee
            switch e.type {
            case .moveToPoint:
                if current.count > 2 { contours.append(current) }
                current = [e.points[0]]
            case .addLineToPoint:
                current.append(e.points[0])
            case .closeSubpath:
                if current.count > 2 { contours.append(current) }
                current = []
            default:
                break // flattened: only lines
            }
        }
        if current.count > 2 { contours.append(current) }

        var rounded: [Contour] = contours.compactMap { contour in
            var points = simplify(contour, tolerance: tolerance)
            if let first = points.first, let last = points.last, hypot(first.x - last.x, first.y - last.y) < 0.5 { points.removeLast() }
            var out: Contour = []
            for p in points {
                let q = (x: Int(p.x.rounded()), y: Int(p.y.rounded()))
                if out.last.map({ $0 == q }) != true { out.append(q) }
            }
            if let first = out.first, out.count > 1, out.last! == first { out.removeLast() }
            return out.count > 2 && abs(signedArea(out.map { CGPoint(x: $0.x, y: $0.y) })) > 4 ? out : nil
        }
        let polygons = rounded.map { $0.map { CGPoint(x: $0.x, y: $0.y) } }
        for i in rounded.indices {
            let depth = polygons.indices.filter { $0 != i && contains(polygons[$0], polygons[i][0]) }.count
            let clockwise = signedArea(polygons[i]) < 0
            if clockwise != depth.isMultiple(of: 2) { rounded[i].reverse() }
        }
        return rounded
    }

    static func signedArea(_ points: [CGPoint]) -> CGFloat {
        var area: CGFloat = 0
        for i in points.indices {
            let a = points[i], b = points[(i + 1) % points.count]
            area += a.x * b.y - b.x * a.y
        }
        return area / 2
    }

    /// Whether `point` is inside `polygon`, by the crossings of a ray to its right.
    static func contains(_ polygon: [CGPoint], _ point: CGPoint) -> Bool {
        var inside = false
        var j = polygon.count - 1
        for i in polygon.indices {
            let a = polygon[i], b = polygon[j]
            if (a.y > point.y) != (b.y > point.y), point.x < (b.x - a.x) * (point.y - a.y) / (b.y - a.y) + a.x { inside.toggle() }
            j = i
        }
        return inside
    }

    /// Douglas–Peucker: the fewest points within `tolerance` of the line through them.
    static func simplify(_ points: [CGPoint], tolerance: CGFloat) -> [CGPoint] {
        guard points.count > 2 else { return points }
        var keep = [Bool](repeating: false, count: points.count)
        keep[0] = true
        keep[points.count - 1] = true
        var spans = [(0, points.count - 1)]
        while let (start, end) = spans.popLast() {
            guard end > start + 1 else { continue }
            let a = points[start], b = points[end]
            let length = max(hypot(b.x - a.x, b.y - a.y), 1e-9)
            var farthest = start, distance: CGFloat = 0
            for i in (start + 1)..<end {
                let p = points[i]
                let d = abs((b.x - a.x) * (a.y - p.y) - (a.x - p.x) * (b.y - a.y)) / length
                if d > distance { distance = d; farthest = i }
            }
            if distance > tolerance {
                keep[farthest] = true
                spans.append((start, farthest))
                spans.append((farthest, end))
            }
        }
        return points.indices.filter { keep[$0] }.map { points[$0] }
    }
}
