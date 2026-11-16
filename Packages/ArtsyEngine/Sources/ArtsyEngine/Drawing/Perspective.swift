import CoreGraphics
import Foundation

/// Perspective over the canvas: one, two or three vanishing points, which lines drawn in
/// perspective run to. A guide, like the grid: drawn over the picture, never into it, and
/// a stroke can be held to it (`PerspectiveStroke`). Canvas pixels, y up, as the guides are.
public struct PerspectiveGuide: Codable, Equatable {
    /// The vanishing points: one, two or three. The first two are on the horizon; a third
    /// is above or below it, where the verticals meet.
    public var points: [CGPoint]
    public var isShown = true
    /// Whether strokes are held to the perspective's lines.
    public var snaps = true

    public init(points: [CGPoint]) {
        self.points = Array(points.prefix(3))
    }

    /// Shown and snapping: whether a stroke is held to it.
    public var holdsStrokes: Bool { isShown && snaps && !points.isEmpty }

    /// One of the ways a line drawn in perspective can run.
    public enum Direction: Equatable {
        /// Toward vanishing point `index`.
        case toward(Int)
        /// Along the horizon (one-point perspective's widths).
        case level
        /// Square to the horizon (the verticals, where no point gathers them).
        case upright

        /// For the diagnostics log.
        public var logName: String {
            switch self {
            case .toward(let index): return "toward point \(index + 1)"
            case .level: return "level"
            case .upright: return "upright"
            }
        }
    }

    /// The horizon's direction, a unit vector running left to right: through the first two
    /// points, or level with the canvas for one point (or two in the same place).
    public var horizon: CGVector {
        guard points.count >= 2 else { return CGVector(dx: 1, dy: 0) }
        var d = CGVector(dx: points[1].x - points[0].x, dy: points[1].y - points[0].y)
        let length = hypot(d.dx, d.dy)
        guard length > 1e-6 else { return CGVector(dx: 1, dy: 0) }
        d = CGVector(dx: d.dx / length, dy: d.dy / length)
        return d.dx < 0 || (d.dx == 0 && d.dy < 0) ? CGVector(dx: -d.dx, dy: -d.dy) : d
    }

    /// The ways a line drawn from `start` can run, each with its unit vector: toward each
    /// point (none toward a point it starts on); for one point, level and upright too; for
    /// two, upright.
    public func directions(from start: CGPoint) -> [(direction: Direction, vector: CGVector)] {
        var result: [(Direction, CGVector)] = []
        for (index, point) in points.enumerated() {
            let d = CGVector(dx: point.x - start.x, dy: point.y - start.y)
            let length = hypot(d.dx, d.dy)
            if length > 1e-3 { result.append((.toward(index), CGVector(dx: d.dx / length, dy: d.dy / length))) }
        }
        let h = horizon
        if points.count == 1 { result.append((.level, h)) }
        if points.count <= 2 { result.append((.upright, CGVector(dx: -h.dy, dy: h.dx))) }
        return result
    }

    /// Of the ways a line from `start` can run, the one nearest `movement`, either way
    /// along it (a line runs both ways).
    public func direction(from start: CGPoint, moving movement: CGVector) -> (direction: Direction, vector: CGVector)? {
        let length = hypot(movement.dx, movement.dy)
        guard length > 1e-6 else { return nil }
        let m = CGVector(dx: movement.dx / length, dy: movement.dy / length)
        return directions(from: start).max { abs($0.vector.dx * m.dx + $0.vector.dy * m.dy) < abs($1.vector.dx * m.dx + $1.vector.dy * m.dy) }
    }

    // MARK: - Handles

    /// What a press can pick up while the perspective is edited.
    public enum Handle: Equatable {
        /// Vanishing point `index`.
        case point(Int)
        /// The horizon, both points on it with it.
        case horizon
    }

    /// How near a press has to come to a handle to pick it up, in screen points.
    public static let handleReach: CGFloat = DrawingGuide.handleReach

    /// The horizon's handle: halfway between the two points on it, for two or three points.
    public var horizonHandle: CGPoint? {
        guard points.count >= 2 else { return nil }
        return CGPoint(x: (points[0].x + points[1].x) / 2, y: (points[0].y + points[1].y) / 2)
    }

    /// Where `handle` is; none for one it does not have.
    public func position(of handle: Handle) -> CGPoint? {
        switch handle {
        case .point(let index): return points.indices.contains(index) ? points[index] : nil
        case .horizon: return horizonHandle
        }
    }

    /// The handle within `reach` canvas pixels of `point`, the nearest if more than one.
    public func handle(near point: CGPoint, reach: CGFloat) -> Handle? {
        var best: (handle: Handle, distance: CGFloat)?
        func consider(_ handle: Handle, at p: CGPoint) {
            let d = hypot(p.x - point.x, p.y - point.y)
            if d <= reach, d < (best?.distance ?? .infinity) { best = (handle, d) }
        }
        for (index, p) in points.enumerated() { consider(.point(index), at: p) }
        if let h = horizonHandle { consider(.horizon, at: h) }
        return best?.handle
    }

    /// `handle` moved by `delta`. One point moves with its horizon; the horizon's handle
    /// moves the two points on it together.
    public mutating func move(_ handle: Handle, by delta: CGVector) {
        func shift(_ index: Int) {
            guard points.indices.contains(index) else { return }
            points[index].x += delta.dx
            points[index].y += delta.dy
        }
        switch handle {
        case .point(let index): shift(index)
        case .horizon: shift(0); shift(1)
        }
    }

    /// The second point level with the first, so the horizon is flat on the canvas.
    public mutating func levelHorizon() {
        guard points.count >= 2 else { return }
        points[1].y = points[0].y
    }

    // MARK: - Drawing

    /// The lines drawn for vanishing point `index`, clipped to `rect`: `count` rays spread
    /// evenly across the rectangle as the point sees it, or all round the point when the
    /// point is inside it.
    public func rays(from index: Int, across rect: CGRect, count: Int = 18) -> [(CGPoint, CGPoint)] {
        guard points.indices.contains(index), count > 0, !rect.isEmpty else { return [] }
        let vp = points[index]
        let corners = [CGPoint(x: rect.minX, y: rect.minY), CGPoint(x: rect.maxX, y: rect.minY),
                       CGPoint(x: rect.maxX, y: rect.maxY), CGPoint(x: rect.minX, y: rect.maxY)]
        let reach = corners.map { hypot($0.x - vp.x, $0.y - vp.y) }.max()! + 1
        var angles: [CGFloat] = []
        if rect.contains(vp) {
            let n = count * 2
            angles = (0..<n).map { CGFloat($0) * 2 * .pi / CGFloat(n) }
        } else {
            // The rectangle's span as the point sees it, measured from the way to its middle
            let middle = atan2(rect.midY - vp.y, rect.midX - vp.x)
            let offsets = corners.map { c -> CGFloat in
                var a = atan2(c.y - vp.y, c.x - vp.x) - middle
                while a > .pi { a -= 2 * .pi }
                while a < -.pi { a += 2 * .pi }
                return a
            }
            let low = offsets.min()!, high = offsets.max()!
            angles = (0..<count).map { middle + low + (high - low) * (CGFloat($0) + 0.5) / CGFloat(count) }
        }
        return angles.compactMap { angle in
            let end = CGPoint(x: vp.x + cos(angle) * reach, y: vp.y + sin(angle) * reach)
            return Self.clip(vp, end, to: rect)
        }
    }

    /// The horizon through the first point, clipped to `rect`; none where it misses.
    public func horizonLine(across rect: CGRect) -> (CGPoint, CGPoint)? {
        guard let first = points.first, !rect.isEmpty else { return nil }
        let h = horizon
        let corners = [CGPoint(x: rect.minX, y: rect.minY), CGPoint(x: rect.maxX, y: rect.maxY),
                       CGPoint(x: rect.minX, y: rect.maxY), CGPoint(x: rect.maxX, y: rect.minY)]
        let reach = corners.map { hypot($0.x - first.x, $0.y - first.y) }.max()! + 1
        return Self.clip(CGPoint(x: first.x - h.dx * reach, y: first.y - h.dy * reach),
                         CGPoint(x: first.x + h.dx * reach, y: first.y + h.dy * reach), to: rect)
    }

    /// The part of the segment from `a` to `b` inside `rect` (Liang–Barsky); none if it
    /// misses, or touches only at a point.
    static func clip(_ a: CGPoint, _ b: CGPoint, to rect: CGRect) -> (CGPoint, CGPoint)? {
        let dx = b.x - a.x, dy = b.y - a.y
        var t0: CGFloat = 0, t1: CGFloat = 1
        for (p, q) in [(-dx, a.x - rect.minX), (dx, rect.maxX - a.x), (-dy, a.y - rect.minY), (dy, rect.maxY - a.y)] {
            if p == 0 {
                if q < 0 { return nil }
            } else {
                let t = q / p
                if p < 0 { t0 = max(t0, t) } else { t1 = min(t1, t) }
            }
        }
        guard t1 - t0 > 1e-9 else { return nil }
        return (CGPoint(x: a.x + t0 * dx, y: a.y + t0 * dy), CGPoint(x: a.x + t1 * dx, y: a.y + t1 * dy))
    }

    // MARK: - Laying out

    /// Perspective with `count` points, from this one: the horizon kept where it was.
    /// One point goes to the horizon's middle. Two take `left` and `right` across the
    /// screen, moved onto the horizon. A third is put at `below` if it is new.
    public func with(points count: Int, left: CGPoint, right: CGPoint, below: CGPoint) -> PerspectiveGuide {
        var result = self
        let count = min(max(count, 1), 3)
        let middle = horizonHandle ?? points.first ?? CGPoint(x: (left.x + right.x) / 2, y: (left.y + right.y) / 2)
        let h = horizon
        /// `p` slid square to the horizon onto it
        func onHorizon(_ p: CGPoint) -> CGPoint {
            let along = (p.x - middle.x) * h.dx + (p.y - middle.y) * h.dy
            return CGPoint(x: middle.x + h.dx * along, y: middle.y + h.dy * along)
        }
        switch count {
        case 1:
            result.points = [middle]
        default:
            var two = points.count >= 2 ? Array(points.prefix(2)) : [onHorizon(left), onHorizon(right)]
            if count == 3 { two.append(points.count >= 3 ? points[2] : below) }
            result.points = two
        }
        return result
    }
}

/// A stroke held to a perspective: kept where it began until the pen has gone far enough
/// to tell which way it is going, then kept to the perspective's line through its start
/// nearest that way until the pen lifts.
public struct PerspectiveStroke {
    public let guide: PerspectiveGuide
    /// Where the stroke began.
    public let anchor: CGPoint
    /// Canvas pixels the pen goes from the start before the line is chosen.
    public let lockDistance: CGFloat
    /// The line chosen, once the pen has gone far enough.
    public private(set) var direction: PerspectiveGuide.Direction?
    private var vector: CGVector?

    /// How far the pen goes before the line is chosen, in screen points.
    public static let lockPoints: CGFloat = 10

    public init(guide: PerspectiveGuide, anchor: CGPoint, zoom: CGFloat) {
        self.guide = guide
        self.anchor = anchor
        lockDistance = Self.lockPoints / max(zoom, 0.01)
    }

    /// Where a sample at `point` goes: on the chosen line, choosing it if the pen has now
    /// gone far enough; at the start until then.
    public mutating func place(_ point: CGPoint) -> CGPoint {
        if vector == nil, hypot(point.x - anchor.x, point.y - anchor.y) >= lockDistance,
           let chosen = guide.direction(from: anchor, moving: CGVector(dx: point.x - anchor.x, dy: point.y - anchor.y)) {
            direction = chosen.direction
            vector = chosen.vector
        }
        return preview(point)
    }

    /// Where a sample at `point` goes, choosing nothing: for a predicted touch.
    public func preview(_ point: CGPoint) -> CGPoint {
        guard let v = vector else { return anchor }
        let along = (point.x - anchor.x) * v.dx + (point.y - anchor.y) * v.dy
        return CGPoint(x: anchor.x + v.dx * along, y: anchor.y + v.dy * along)
    }
}
