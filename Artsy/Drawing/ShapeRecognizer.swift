import CoreGraphics

/// The shape a rough stroke was meant to be.
enum RecognizedShape: Equatable {
    case line(from: CGPoint, to: CGPoint)
    /// Closed, corners in drawing order.
    case polygon([CGPoint])
    case ellipse(center: CGPoint, radii: CGSize, angle: CGFloat)

    var name: String {
        switch self {
        case .line: return "Line"
        case .polygon(let corners):
            switch corners.count {
            case 3: return "Triangle"
            case 4: return Self.isRectangle(corners) ? "Rectangle" : "Quadrilateral"
            default: return "Polygon"
            }
        case .ellipse(_, let radii, _):
            return abs(radii.width - radii.height) < 0.001 ? "Circle" : "Ellipse"
        }
    }

    /// Positions along the shape about `spacing` apart, for a stroke path to follow; a
    /// closed shape comes back to its first point.
    func points(spacing: CGFloat) -> [CGPoint] {
        switch self {
        case .line(let a, let b):
            return Self.segment(a, b, spacing: spacing, includeEnd: true)
        case .polygon(let corners):
            var result: [CGPoint] = []
            for (i, corner) in corners.enumerated() {
                result += Self.segment(corner, corners[(i + 1) % corners.count], spacing: spacing, includeEnd: false)
            }
            result.append(corners[0])
            return result
        case .ellipse(let center, let radii, let angle):
            let perimeter = CGFloat.pi * (3 * (radii.width + radii.height)
                - ((3 * radii.width + radii.height) * (radii.width + 3 * radii.height)).squareRoot())
            let count = max(24, Int(perimeter / spacing))
            let c = cos(angle), s = sin(angle)
            return (0...count).map { i in
                let t = CGFloat(i) / CGFloat(count) * 2 * .pi
                let x = radii.width * cos(t), y = radii.height * sin(t)
                return CGPoint(x: center.x + x * c - y * s, y: center.y + x * s + y * c)
            }
        }
    }

    private static func segment(_ a: CGPoint, _ b: CGPoint, spacing: CGFloat, includeEnd: Bool) -> [CGPoint] {
        let length = hypot(b.x - a.x, b.y - a.y)
        let steps = max(1, Int(length / spacing))
        return (0..<(includeEnd ? steps + 1 : steps)).map { i in
            let t = CGFloat(i) / CGFloat(steps)
            return CGPoint(x: a.x + (b.x - a.x) * t, y: a.y + (b.y - a.y) * t)
        }
    }

    static func isRectangle(_ corners: [CGPoint]) -> Bool {
        guard corners.count == 4 else { return false }
        for i in 0..<4 {
            let p = corners[(i + 3) % 4], q = corners[i], r = corners[(i + 1) % 4]
            let a = CGPoint(x: p.x - q.x, y: p.y - q.y), b = CGPoint(x: r.x - q.x, y: r.y - q.y)
            let cosine = (a.x * b.x + a.y * b.y) / max(hypot(a.x, a.y) * hypot(b.x, b.y), 1e-6)
            if abs(cosine) > 0.25 { return false }   // more than ~14° off a right angle
        }
        return true
    }
}

/// Recognises what a rough stroke was meant to be — a line, a circle or ellipse, a
/// rectangle, a triangle or another simple polygon — so a stroke can snap to it when the
/// pen holds still at its end. Returns nil for anything else, which is most strokes.
enum ShapeRecognizer {
    static func recognize(_ raw: [CGPoint]) -> RecognizedShape? {
        var distinct: [CGPoint] = []
        for p in raw where distinct.last.map({ hypot(p.x - $0.x, p.y - $0.y) > 0.5 }) ?? true {
            distinct.append(p)
        }
        guard distinct.count >= 8 else { return nil }
        // Take the tremor out, so it does not count as length or as corners
        let positions = distinct.indices.map { i -> CGPoint in
            let window = distinct[max(0, i - 2)...min(distinct.count - 1, i + 2)]
            return CGPoint(x: window.map(\.x).reduce(0, +) / CGFloat(window.count),
                           y: window.map(\.y).reduce(0, +) / CGFloat(window.count))
        }
        guard let first = positions.first, let last = positions.last else { return nil }
        let xs = positions.map(\.x), ys = positions.map(\.y)
        let bounds = CGRect(x: xs.min()!, y: ys.min()!, width: xs.max()! - xs.min()!, height: ys.max()! - ys.min()!)
        let diagonal = hypot(bounds.width, bounds.height)
        guard diagonal >= 16 else { return nil }
        let length = zip(positions, positions.dropFirst()).reduce(CGFloat(0)) { $0 + hypot($1.1.x - $1.0.x, $1.1.y - $1.0.y) }

        // A line: goes nearly straight from where it started to where it ended, staying
        // close to the line that fits it best (its ends wobble too, so not the chord)
        let chord = hypot(last.x - first.x, last.y - first.y)
        if chord > 0.7 * length {
            let (origin, direction) = fitLine(positions)
            let deviation = positions.map { p in
                abs((p.x - origin.x) * direction.y - (p.y - origin.y) * direction.x)
            }.max() ?? 0
            guard deviation <= max(0.07 * length, 3) else { return nil }
            func onLine(_ p: CGPoint) -> CGPoint {
                let t = (p.x - origin.x) * direction.x + (p.y - origin.y) * direction.y
                return CGPoint(x: origin.x + direction.x * t, y: origin.y + direction.y * t)
            }
            return .line(from: onLine(first), to: onLine(last))
        }

        // Otherwise it has to come back to where it started
        let gap = hypot(last.x - first.x, last.y - first.y)
        guard gap <= max(0.15 * diagonal, 10), length >= 1.9 * diagonal else { return nil }
        let ring = resampleClosed(positions, count: 96)

        // A few sharp corners with the ring running straight between them make a polygon;
        // a ring that bends evenly is an ellipse. Corners are where a smoothed ring turns
        // far faster than it does on average; wobbles, smoothed at the scale of the shape,
        // do not.
        let corners = cornersByTurning(of: ring)
        if (3...6).contains(corners.count), ringIsConvexEnough(corners),
           ringFollows(corners, ring: ring, tolerance: max(0.08 * diagonal, 4)) {
            if corners.count == 4, RecognizedShape.isRectangle(corners) {
                return .polygon(rectangle(fitting: ring, like: corners))
            }
            return .polygon(corners)
        }
        if let ellipse = fitEllipse(ring) { return ellipse }
        return nil
    }

    /// The line through `positions` that fits them best: a point on it and its direction.
    private static func fitLine(_ positions: [CGPoint]) -> (origin: CGPoint, direction: CGPoint) {
        let n = CGFloat(positions.count)
        let centroid = CGPoint(x: positions.map(\.x).reduce(0, +) / n, y: positions.map(\.y).reduce(0, +) / n)
        var cxx: CGFloat = 0, cyy: CGFloat = 0, cxy: CGFloat = 0
        for p in positions {
            let dx = p.x - centroid.x, dy = p.y - centroid.y
            cxx += dx * dx; cyy += dy * dy; cxy += dx * dy
        }
        let angle = 0.5 * atan2(2 * cxy, cxx - cyy)
        return (centroid, CGPoint(x: cos(angle), y: sin(angle)))
    }

    /// The ring's corners: where it turns, once smoothed at the scale of the shape, far
    /// faster than it turns on average, and fast in its own right. A circle turns evenly
    /// and has none; an ellipse has at most its two tips.
    private static func cornersByTurning(of ring: [CGPoint]) -> [CGPoint] {
        let n = ring.count
        let smoothed = (0..<n).map { i -> CGPoint in
            var sum = CGPoint.zero
            for k in -3...3 { let p = ring[(i + k + n) % n]; sum.x += p.x; sum.y += p.y }
            return CGPoint(x: sum.x / 7, y: sum.y / 7)
        }
        // Turning at each point: the change in direction from the step before to the step after
        let turn = (0..<n).map { i -> CGFloat in
            let p = smoothed[(i + n - 1) % n], q = smoothed[i], r = smoothed[(i + 1) % n]
            let a = atan2(q.y - p.y, q.x - p.x), b = atan2(r.y - q.y, r.x - q.x)
            var d = b - a
            while d > .pi { d -= 2 * .pi }
            while d < -.pi { d += 2 * .pi }
            return abs(d)
        }
        let mean = turn.reduce(0, +) / CGFloat(n)
        let threshold = max(mean * 2.5, 8 * CGFloat.pi / 180)
        var corners: [Int] = []
        for i in 0..<n where turn[i] >= threshold {
            // A local maximum, and not a neighbour of a corner already found
            let isPeak = (1...6).allSatisfy { turn[i] >= turn[(i + $0) % n] && turn[i] >= turn[(i - $0 + n) % n] }
            if isPeak, corners.allSatisfy({ min((i - $0 + n) % n, ($0 - i + n) % n) > 6 }) { corners.append(i) }
        }
        return corners.map { ring[$0] }
    }

    /// Whether every point of the ring lies within `tolerance` of the polygon's edges.
    private static func ringFollows(_ corners: [CGPoint], ring: [CGPoint], tolerance: CGFloat) -> Bool {
        ring.allSatisfy { p in
            corners.indices.contains { i in
                distance(from: p, toSegment: corners[i], corners[(i + 1) % corners.count]) <= tolerance
            }
        }
    }

    private static func distance(from p: CGPoint, toSegment a: CGPoint, _ b: CGPoint) -> CGFloat {
        let dx = b.x - a.x, dy = b.y - a.y
        let lengthSquared = dx * dx + dy * dy
        guard lengthSquared > 1e-9 else { return hypot(p.x - a.x, p.y - a.y) }
        let t = max(0, min(1, ((p.x - a.x) * dx + (p.y - a.y) * dy) / lengthSquared))
        return hypot(p.x - (a.x + dx * t), p.y - (a.y + dy * t))
    }

    // MARK: - Pieces

    private static func distance(from p: CGPoint, toLineThrough a: CGPoint, _ b: CGPoint) -> CGFloat {
        let dx = b.x - a.x, dy = b.y - a.y
        let length = hypot(dx, dy)
        guard length > 1e-6 else { return hypot(p.x - a.x, p.y - a.y) }
        return abs((p.x - a.x) * dy - (p.y - a.y) * dx) / length
    }

    /// `count` points evenly spaced along the closed path through `positions`, starting at
    /// the point farthest from the centre (a corner, if there are corners).
    private static func resampleClosed(_ positions: [CGPoint], count: Int) -> [CGPoint] {
        let centroid = CGPoint(x: positions.map(\.x).reduce(0, +) / CGFloat(positions.count),
                               y: positions.map(\.y).reduce(0, +) / CGFloat(positions.count))
        let start = positions.indices.max { hypot(positions[$0].x - centroid.x, positions[$0].y - centroid.y)
                                            < hypot(positions[$1].x - centroid.x, positions[$1].y - centroid.y) }!
        let loop = Array(positions[start...] + positions[..<start]) + [positions[start]]
        var cumulative: [CGFloat] = [0]
        for (a, b) in zip(loop, loop.dropFirst()) { cumulative.append(cumulative.last! + hypot(b.x - a.x, b.y - a.y)) }
        let total = cumulative.last!
        var result: [CGPoint] = []
        var segment = 0
        for i in 0..<count {
            let target = total * CGFloat(i) / CGFloat(count)
            while segment + 1 < cumulative.count - 1, cumulative[segment + 1] < target { segment += 1 }
            let span = cumulative[segment + 1] - cumulative[segment]
            let t = span > 0 ? (target - cumulative[segment]) / span : 0
            let a = loop[segment], b = loop[segment + 1]
            result.append(CGPoint(x: a.x + (b.x - a.x) * t, y: a.y + (b.y - a.y) * t))
        }
        return result
    }

    /// Hand-drawn polygons are convex or nearly; a self-crossing scribble is not a shape.
    private static func ringIsConvexEnough(_ corners: [CGPoint]) -> Bool {
        var signs = 0, total = 0
        for i in corners.indices {
            let p = corners[(i + corners.count - 1) % corners.count], q = corners[i], r = corners[(i + 1) % corners.count]
            let cross = (q.x - p.x) * (r.y - q.y) - (q.y - p.y) * (r.x - q.x)
            total += 1
            if cross > 0 { signs += 1 }
        }
        return signs == 0 || signs == total
    }

    /// The rectangle the ring was going for: turned like its longest side (or squared up
    /// when nearly so), sized to hold the ring.
    private static func rectangle(fitting ring: [CGPoint], like corners: [CGPoint]) -> [CGPoint] {
        var angle: CGFloat = 0, longest: CGFloat = 0
        for i in 0..<4 {
            let a = corners[i], b = corners[(i + 1) % 4]
            let length = hypot(b.x - a.x, b.y - a.y)
            if length > longest { longest = length; angle = atan2(b.y - a.y, b.x - a.x) }
        }
        // Snap to the axes when within a few degrees
        let quarter = CGFloat.pi / 2
        let nearest = (angle / quarter).rounded() * quarter
        if abs(angle - nearest) < 4 * .pi / 180 { angle = nearest }
        let c = cos(angle), s = sin(angle)
        let centroid = CGPoint(x: ring.map(\.x).reduce(0, +) / CGFloat(ring.count), y: ring.map(\.y).reduce(0, +) / CGFloat(ring.count))
        // In the rectangle's own frame, the ring's extent — trimmed a little, since wobbles
        // reach outward more than inward
        let local = ring.map { p -> CGPoint in
            let dx = p.x - centroid.x, dy = p.y - centroid.y
            return CGPoint(x: dx * c + dy * s, y: -dx * s + dy * c)
        }
        let xs = local.map(\.x).sorted(), ys = local.map(\.y).sorted()
        let trim = ring.count / 50
        let minX = xs[trim], maxX = xs[xs.count - 1 - trim], minY = ys[trim], maxY = ys[ys.count - 1 - trim]
        return [CGPoint(x: minX, y: minY), CGPoint(x: maxX, y: minY), CGPoint(x: maxX, y: maxY), CGPoint(x: minX, y: maxY)].map { p in
            CGPoint(x: centroid.x + p.x * c - p.y * s, y: centroid.y + p.x * s + p.y * c)
        }
    }

    /// The ellipse through the ring: its axes from the ring's spread, then the radii that
    /// fit the ring best in least squares. Nil when the ring does not sit on it.
    private static func fitEllipse(_ ring: [CGPoint]) -> RecognizedShape? {
        let n = CGFloat(ring.count)
        let center = CGPoint(x: ring.map(\.x).reduce(0, +) / n, y: ring.map(\.y).reduce(0, +) / n)
        var cxx: CGFloat = 0, cyy: CGFloat = 0, cxy: CGFloat = 0
        for p in ring {
            let dx = p.x - center.x, dy = p.y - center.y
            cxx += dx * dx; cyy += dy * dy; cxy += dx * dy
        }
        let angle = 0.5 * atan2(2 * cxy, cxx - cyy)
        let c = cos(angle), s = sin(angle)

        // In the ellipse's frame, solve (u/a)² + (v/b)² = 1 for 1/a² and 1/b²
        var su4: CGFloat = 0, sv4: CGFloat = 0, su2v2: CGFloat = 0, su2: CGFloat = 0, sv2: CGFloat = 0
        for p in ring {
            let dx = p.x - center.x, dy = p.y - center.y
            let u = dx * c + dy * s, v = -dx * s + dy * c
            su4 += u * u * u * u; sv4 += v * v * v * v; su2v2 += u * u * v * v; su2 += u * u; sv2 += v * v
        }
        let det = su4 * sv4 - su2v2 * su2v2
        guard abs(det) > 1e-9 else { return nil }
        let invA2 = (su2 * sv4 - sv2 * su2v2) / det, invB2 = (su4 * sv2 - su2v2 * su2) / det
        guard invA2 > 0, invB2 > 0 else { return nil }
        var radii = CGSize(width: 1 / invA2.squareRoot(), height: 1 / invB2.squareRoot())

        // How far the ring strays from that ellipse, relative to its size
        let stray = ring.map { p -> CGFloat in
            let dx = p.x - center.x, dy = p.y - center.y
            let u = (dx * c + dy * s) / radii.width, v = (-dx * s + dy * c) / radii.height
            return abs(hypot(u, v) - 1)
        }.reduce(0, +) / n
        guard stray <= 0.12 else { return nil }

        if max(radii.width, radii.height) / min(radii.width, radii.height) < 1.12 {
            let r = (radii.width + radii.height) / 2
            radii = CGSize(width: r, height: r)
        }
        return .ellipse(center: center, radii: radii, angle: angle)
    }
}
