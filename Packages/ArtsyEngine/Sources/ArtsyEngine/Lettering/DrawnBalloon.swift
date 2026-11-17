import CoreGraphics
import Foundation

/// A balloon's body as the artist drew it: the outline round the balloon's middle, in units
/// of the ellipse inside it, so it can be laid on any ellipse its words need and keep its
/// wobbles; and that ellipse's radii as drawn, the least the body is drawn at.
public struct DrawnOutline: Codable, Equatable {
    /// The outline, closed, every point on or outside the unit circle.
    public var points: [CGPoint]
    /// The ellipse inside the outline as drawn, in canvas pixels.
    public var radii: CGSize

    public init(points: [CGPoint], radii: CGSize) {
        self.points = points
        self.radii = radii
    }

    /// The outline laid on the ellipse at `center` with half-axes `a` and `b`, as a smooth
    /// closed curve through its points.
    public func path(center: CGPoint, a: CGFloat, b: CGFloat) -> CGPath {
        BalloonSketch.smoothLoop(points.map { CGPoint(x: center.x + $0.x * a, y: center.y + $0.y * b) })
    }
}

/// Turning a balloon drawn by hand, one stroke round where its words go, into a balloon's
/// parts: its outline, its middle, and, if a point was drawn sticking out of it, its tail.
public enum BalloonSketch {
    /// What a sketch makes.
    public struct Fitted: Equatable {
        public var outline: DrawnOutline
        /// The middle of the ellipse inside the outline, where the words go.
        public var center: CGPoint
        /// The tip of a tail drawn as a point of the loop; nil if none was.
        public var tail: CGPoint?
        /// How wide the drawn tail was where it met the body, in sizes of the lettering.
        public var tailBase: CGFloat?
    }

    /// How far apart, as a share of its size, a loop's ends may be and still close.
    static let gap: CGFloat = 0.25
    /// The least a balloon is across, in sizes of the lettering.
    static let leastAcross: CGFloat = 2.5

    /// The balloon in `stroke`, drawn in canvas pixels, lettered at `size`; a point drawn
    /// sticking out is taken for its tail if `takesTail`. Nil if the stroke is not a loop,
    /// or too small to hold a word.
    public static func fit(_ stroke: [CGPoint], size: CGFloat, takesTail: Bool) -> Fitted? {
        var points: [CGPoint] = []
        for p in stroke where p.x.isFinite && p.y.isFinite {
            if let last = points.last, hypot(p.x - last.x, p.y - last.y) < 0.01 { continue }
            points.append(p)
        }
        guard points.count >= 8, size > 0 else { return nil }
        let bounds = boundingBox(points)
        guard min(bounds.width, bounds.height) >= size * leastAcross else { return nil }
        guard let loop = closed(points, reach: max(size * 1.5, gap * max(bounds.width, bounds.height))) else { return nil }

        let count = min(max(Int(perimeter(loop) / (size * 0.35)), 48), 240)
        var body = smoothed(resampled(loop, count: count))
        var tip: CGPoint?, base: CGFloat?
        if takesTail, let tail = drawnTail(in: body, original: loop, size: size) {
            tip = tail.tip
            base = tail.base
            body = smoothed(resampled(tail.body, count: count))
        }

        // The ellipse inside: the outline's spread for its proportions, about its area's
        // middle, scaled until it touches the outline from inside
        let c = centroid(body)
        let (a0, b0) = spread(body, about: c)
        guard a0 > 0, b0 > 0 else { return nil }
        let reach = body.map { hypot(($0.x - c.x) / a0, ($0.y - c.y) / b0) }.min() ?? 0
        guard reach >= 0.33 else { return nil }
        let a = a0 * reach, b = b0 * reach
        let outline = DrawnOutline(points: body.map { CGPoint(x: ($0.x - c.x) / a, y: ($0.y - c.y) / b) },
                                   radii: CGSize(width: a, height: b))
        // A tip inside the body is no tail
        if let t = tip, smoothLoop(body).contains(t) {
            tip = nil
            base = nil
        }
        return Fitted(outline: outline, center: c, tail: tip, tailBase: base)
    }

    // MARK: - Closing the loop

    /// The loop in `points`: from where its ends come nearest each other, within its first
    /// and last quarters, trimming what overshoots; nil if they come no nearer than `reach`.
    static func closed(_ points: [CGPoint], reach: CGFloat) -> [CGPoint]? {
        let n = points.count
        let quarter = max(2, n / 4)
        var best: (i: Int, j: Int, d: CGFloat)?
        for i in 0..<quarter {
            for j in (n - quarter)..<n where j > i + 4 {
                let d = hypot(points[i].x - points[j].x, points[i].y - points[j].y)
                if d < (best?.d ?? .infinity) { best = (i, j, d) }
            }
        }
        guard let best, best.d <= reach else { return nil }
        return Array(points[best.i...best.j])
    }

    // MARK: - A drawn tail

    /// A point of the loop sticking well out of it, taken for a tail: its tip (the farthest
    /// drawn point that way), how wide it was at its base in lettering sizes, and the loop
    /// without it.
    static func drawnTail(in loop: [CGPoint], original: [CGPoint], size: CGFloat)
        -> (tip: CGPoint, base: CGFloat, body: [CGPoint])? {
        let n = loop.count
        let c = centroid(loop)
        let (a0, b0) = spread(loop, about: c)
        guard a0 > 0, b0 > 0 else { return nil }
        let r = loop.map { hypot(($0.x - c.x) / a0, ($0.y - c.y) / b0) }
        let median = r.sorted()[n / 2]
        guard let k = r.indices.max(by: { r[$0] < r[$1] }), r[k] >= median * 1.5 else { return nil }
        // Out from the point both ways to where the loop is back near its usual reach: the
        // tail's base, as drawn
        var i0 = k, i1 = k, steps = 0
        while r[(i0 - 1 + n) % n] > median * 1.125, steps < n / 3 { i0 = (i0 - 1 + n) % n; steps += 1 }
        i0 = (i0 - 1 + n) % n
        steps = 0
        while r[(i1 + 1) % n] > median * 1.125, steps < n / 3 { i1 = (i1 + 1) % n; steps += 1 }
        i1 = (i1 + 1) % n
        let left = loop[i0], right = loop[i1]
        let width = hypot(left.x - right.x, left.y - right.y)
        let mid = CGPoint(x: (left.x + right.x) / 2, y: (left.y + right.y) / 2)
        let length = hypot(loop[k].x - mid.x, loop[k].y - mid.y)
        guard length >= size * 1.5, length >= width, (i1 - i0 + n) % n < n / 3 else { return nil }
        // Cut wider than the base, so none of its flanks or the dents beside them is left in
        // the outline: on to where the loop is at its usual reach, and a twenty-fourth of the
        // loop more each way
        steps = 0
        while r[(i0 - 1 + n) % n] > median, steps < n / 8 { i0 = (i0 - 1 + n) % n; steps += 1 }
        let beyond = max(2, n / 24)
        i0 = (i0 - beyond + n) % n
        steps = 0
        while r[(i1 + 1) % n] > median, steps < n / 8 { i1 = (i1 + 1) % n; steps += 1 }
        i1 = (i1 + beyond) % n
        let inside = (i1 - i0 + n) % n
        guard inside < n / 2 else { return nil }
        // The tip as drawn: smoothing blunts a point
        let way = CGVector(dx: loop[k].x - mid.x, dy: loop[k].y - mid.y)
        let tip = original.max { ($0.x - mid.x) * way.dx + ($0.y - mid.y) * way.dy < ($1.x - mid.x) * way.dx + ($1.y - mid.y) * way.dy }
            ?? loop[k]
        // The loop from the cut's far end round to its near end, the point left out, and the
        // gap bridged along the loop's ellipse, its reach eased from one end of the cut to the
        // other, the way round the point went
        var body: [CGPoint] = []
        var index = i1
        while index != i0 {
            body.append(loop[index])
            index = (index + 1) % n
        }
        body.append(loop[i0])
        func angle(_ p: CGPoint) -> CGFloat { atan2((p.y - c.y) / b0, (p.x - c.x) / a0) }
        func wrapped(_ x: CGFloat) -> CGFloat { atan2(sin(x), cos(x)) }
        let from = angle(loop[i0]), to = angle(loop[i1])
        var turn = wrapped(to - from)
        // The bridge passes the point's own angle, as the loop did
        let towardPoint = wrapped(angle(loop[k]) - from)
        if (turn >= 0) != (towardPoint >= 0) || abs(towardPoint) > abs(turn) {
            turn += turn >= 0 ? -2 * .pi : 2 * .pi
        }
        let reachFrom = r[i0], reachTo = r[i1]
        for step in 1..<max(inside, 2) {
            let t = CGFloat(step) / CGFloat(max(inside, 2))
            let theta = from + turn * t
            let reach = reachFrom + (reachTo - reachFrom) * t
            body.append(CGPoint(x: c.x + a0 * reach * cos(theta), y: c.y + b0 * reach * sin(theta)))
        }
        return (tip, max(width / size, 0.5), body)
    }

    // MARK: - Shapes

    /// A smooth closed curve through `points` (Catmull–Rom, as cubic Béziers).
    static func smoothLoop(_ points: [CGPoint]) -> CGPath {
        let path = CGMutablePath()
        let n = points.count
        guard n >= 3 else { return path }
        path.move(to: points[0])
        for i in 0..<n {
            let p0 = points[(i - 1 + n) % n], p1 = points[i], p2 = points[(i + 1) % n], p3 = points[(i + 2) % n]
            path.addCurve(to: p2, control1: CGPoint(x: p1.x + (p2.x - p0.x) / 6, y: p1.y + (p2.y - p0.y) / 6),
                          control2: CGPoint(x: p2.x - (p3.x - p1.x) / 6, y: p2.y - (p3.y - p1.y) / 6))
        }
        path.closeSubpath()
        return path
    }

    static func boundingBox(_ points: [CGPoint]) -> CGRect {
        let xs = points.map(\.x), ys = points.map(\.y)
        return CGRect(x: xs.min()!, y: ys.min()!, width: xs.max()! - xs.min()!, height: ys.max()! - ys.min()!)
    }

    /// The length round a closed loop.
    static func perimeter(_ loop: [CGPoint]) -> CGFloat {
        zip(loop, loop.dropFirst() + [loop[0]]).reduce(0) { $0 + hypot($1.1.x - $1.0.x, $1.1.y - $1.0.y) }
    }

    /// `count` points evenly spaced round the closed loop.
    static func resampled(_ loop: [CGPoint], count: Int) -> [CGPoint] {
        let closedLoop = loop + [loop[0]]
        let total = perimeter(loop)
        guard total > 0, count > 0 else { return loop }
        let step = total / CGFloat(count)
        var result: [CGPoint] = [loop[0]]
        var segment = 0, along: CGFloat = 0, target = step
        while result.count < count, segment < closedLoop.count - 1 {
            let a = closedLoop[segment], b = closedLoop[segment + 1]
            let length = hypot(b.x - a.x, b.y - a.y)
            if along + length >= target, length > 0 {
                let t = (target - along) / length
                result.append(CGPoint(x: a.x + (b.x - a.x) * t, y: a.y + (b.y - a.y) * t))
                target += step
            } else {
                along += length
                segment += 1
            }
        }
        return result
    }

    /// The loop with each point moved toward its neighbours (twice, a quarter each way), so
    /// the pen's jitter goes and its wobbles stay.
    static func smoothed(_ loop: [CGPoint]) -> [CGPoint] {
        var points = loop
        let n = points.count
        guard n >= 3 else { return points }
        for _ in 0..<2 {
            points = (0..<n).map { i in
                let a = points[(i - 1 + n) % n], b = points[i], c = points[(i + 1) % n]
                return CGPoint(x: (a.x + 2 * b.x + c.x) / 4, y: (a.y + 2 * b.y + c.y) / 4)
            }
        }
        return points
    }

    /// The middle of the area a closed loop holds.
    static func centroid(_ loop: [CGPoint]) -> CGPoint {
        var area: CGFloat = 0, x: CGFloat = 0, y: CGFloat = 0
        for (p, q) in zip(loop, loop.dropFirst() + [loop[0]]) {
            let cross = p.x * q.y - q.x * p.y
            area += cross
            x += (p.x + q.x) * cross
            y += (p.y + q.y) * cross
        }
        guard abs(area) > 1e-9 else {
            return CGPoint(x: loop.map(\.x).reduce(0, +) / CGFloat(loop.count), y: loop.map(\.y).reduce(0, +) / CGFloat(loop.count))
        }
        return CGPoint(x: x / (3 * area), y: y / (3 * area))
    }

    /// The half-axes of the ellipse with the loop's spread about `c`: points evenly round an
    /// ellipse spread √½ of its half-axis either way.
    static func spread(_ loop: [CGPoint], about c: CGPoint) -> (CGFloat, CGFloat) {
        let n = CGFloat(loop.count)
        let vx = loop.reduce(0) { $0 + ($1.x - c.x) * ($1.x - c.x) } / n
        let vy = loop.reduce(0) { $0 + ($1.y - c.y) * ($1.y - c.y) } / n
        return (sqrt(2 * vx), sqrt(2 * vy))
    }
}
