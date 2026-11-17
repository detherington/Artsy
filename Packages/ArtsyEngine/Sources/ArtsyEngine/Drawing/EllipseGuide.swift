import CoreGraphics
import Foundation

/// An ellipse template laid on the canvas: a stroke laid against its outline runs round
/// it, and with `everySize` a stroke anywhere runs round the ellipse of its shape through
/// where it lands, like a template's row of sizes (see `HeldStroke`). Canvas pixels, y up.
public struct EllipseGuide: Codable, Equatable {
    public var centre: CGPoint
    /// Half its length along its first axis (`width`) and across it (`height`).
    public var radii: CGSize
    /// The first axis's angle on the canvas, in radians, anticlockwise from level.
    public var rotation: CGFloat
    public var isShown = true
    /// Whether strokes laid against it run round it.
    public var snaps = true
    /// Whether a stroke anywhere runs round the ellipse of its shape through where it lands.
    public var everySize = false

    public init(centre: CGPoint, radii: CGSize, rotation: CGFloat = 0) {
        self.centre = centre
        self.radii = radii
        self.rotation = rotation
    }

    /// One laid out at `centre` with its first axis reaching to `axisEnd`, at `degree`.
    public init(centre: CGPoint, axisEnd: CGPoint, degree: CGFloat) {
        let length = max(hypot(axisEnd.x - centre.x, axisEnd.y - centre.y), Self.minimumRadius)
        self.init(centre: centre, radii: CGSize(width: length, height: length * sin(degree * .pi / 180)),
                  rotation: atan2(axisEnd.y - centre.y, axisEnd.x - centre.x))
    }

    /// Shown, snapping and not flat: whether it can hold a stroke.
    public var holdsStrokes: Bool { isShown && snaps && min(radii.width, radii.height) > 1e-3 }

    /// No radius goes below a pixel, so it never folds flat.
    static let minimumRadius: CGFloat = 1

    // MARK: - Its degree

    /// Its degree, as a template marks it: the angle a circle is seen at to look like this
    /// ellipse, from near 0 (flat) to 90 (a circle).
    public var degree: CGFloat {
        let long = max(radii.width, radii.height), short = min(radii.width, radii.height)
        guard long > 0 else { return 90 }
        return asin(min(short / long, 1)) * 180 / .pi
    }

    /// The degrees `setDegree` steps between.
    public static let degreeStep: CGFloat = 5

    /// At `degree` (5 to 90), its long axis kept.
    public mutating func setDegree(_ degree: CGFloat) {
        let d = min(max(degree, Self.degreeStep), 90)
        let short = max(max(radii.width, radii.height) * sin(d * .pi / 180), Self.minimumRadius)
        if radii.width >= radii.height { radii.height = short } else { radii.width = short }
    }

    /// Its degree to the nearest step, moved `steps` steps on.
    public mutating func stepDegree(by steps: Int) {
        let current = (degree / Self.degreeStep).rounded() * Self.degreeStep
        setDegree(current + CGFloat(steps) * Self.degreeStep)
    }

    /// Its axes turned to the nearest 15°.
    public mutating func straighten() {
        rotation = RulerGuide.nearestStep(rotation)
    }

    // MARK: - Its own frame

    /// `point` in the ellipse's own frame: from its centre, its first axis along x.
    public func local(_ point: CGPoint) -> CGPoint {
        let dx = point.x - centre.x, dy = point.y - centre.y
        let c = cos(rotation), s = sin(rotation)
        return CGPoint(x: dx * c + dy * s, y: -dx * s + dy * c)
    }

    /// A point of the ellipse's own frame on the canvas.
    public func world(_ point: CGPoint) -> CGPoint {
        let c = cos(rotation), s = sin(rotation)
        return CGPoint(x: centre.x + point.x * c - point.y * s, y: centre.y + point.x * s + point.y * c)
    }

    /// The ellipse's own frame onto the canvas, for drawing it: a rectangle about the
    /// origin `2 × radii` across, under this, is the ellipse's bounds.
    public var placement: CGAffineTransform {
        CGAffineTransform(rotationAngle: rotation).concatenating(CGAffineTransform(translationX: centre.x, y: centre.y))
    }

    // MARK: - Points on it

    /// The size, as a multiple of this one, of the ellipse of its shape through `point`.
    public func scale(through point: CGPoint) -> CGFloat {
        let q = local(point)
        let x = q.x / max(radii.width, 1e-9), y = q.y / max(radii.height, 1e-9)
        return sqrt(x * x + y * y)
    }

    /// The point nearest `point` on the ellipse of its shape `scale` times its size.
    public func nearest(to point: CGPoint, scale: CGFloat = 1) -> CGPoint {
        world(Self.nearestOnEllipse(a: radii.width * scale, b: radii.height * scale, to: local(point)))
    }

    /// How far `point` is from its outline.
    public func distance(to point: CGPoint) -> CGFloat {
        let n = nearest(to: point)
        return hypot(point.x - n.x, point.y - n.y)
    }

    /// The point on the ellipse with half-axes `a` along x and `b` along y, about the
    /// origin, nearest `p`: a few rounds of the iteration that walks a quarter of the
    /// ellipse by its curvature (Luc Maisonobe, as condensed by Chris Gilbert), exact to
    /// well under a pixel at any size.
    static func nearestOnEllipse(a: CGFloat, b: CGFloat, to p: CGPoint) -> CGPoint {
        guard a > 1e-9, b > 1e-9 else { return .zero }
        let px = abs(p.x), py = abs(p.y)
        var tx: CGFloat = 0.70710678, ty: CGFloat = 0.70710678
        for _ in 0..<4 {
            let x = a * tx, y = b * ty
            let ex = (a * a - b * b) * tx * tx * tx / a
            let ey = (b * b - a * a) * ty * ty * ty / b
            let rx = x - ex, ry = y - ey
            let qx = px - ex, qy = py - ey
            let r = hypot(rx, ry), q = hypot(qx, qy)
            guard q > 1e-12 else { break }
            tx = min(1, max(0, (qx * r / q + ex) / a))
            ty = min(1, max(0, (qy * r / q + ey) / b))
            let t = hypot(tx, ty)
            guard t > 1e-12 else { tx = 1; ty = 0; break }
            tx /= t
            ty /= t
        }
        return CGPoint(x: (p.x < 0 ? -1 : 1) * a * tx, y: (p.y < 0 ? -1 : 1) * b * ty)
    }

    // MARK: - Handles

    /// What a press can pick up while the ellipse is edited.
    public enum Handle: Equatable {
        /// The whole ellipse.
        case centre
        /// The end of its first axis: turns it and sets that radius.
        case axis
        /// The end of its second axis: sets the radius across.
        case across
    }

    public func position(of handle: Handle) -> CGPoint {
        switch handle {
        case .centre: return centre
        case .axis: return world(CGPoint(x: radii.width, y: 0))
        case .across: return world(CGPoint(x: 0, y: radii.height))
        }
    }

    /// The handle within `reach` canvas pixels of `point`, the nearest if more than one.
    public func handle(near point: CGPoint, reach: CGFloat) -> Handle? {
        [Handle.centre, .axis, .across]
            .map { ($0, hypot(position(of: $0).x - point.x, position(of: $0).y - point.y)) }
            .filter { $0.1 <= reach }
            .min { $0.1 < $1.1 }?.0
    }

    /// `handle` moved by `delta`: the centre moves the ellipse; the first axis's end turns
    /// it and sets that radius; the second's sets the radius across.
    public mutating func move(_ handle: Handle, by delta: CGVector) {
        switch handle {
        case .centre:
            centre.x += delta.dx
            centre.y += delta.dy
        case .axis:
            let p = position(of: .axis)
            let v = CGVector(dx: p.x + delta.dx - centre.x, dy: p.y + delta.dy - centre.y)
            let length = hypot(v.dx, v.dy)
            guard length > 1e-6 else { return }
            rotation = atan2(v.dy, v.dx)
            radii.width = max(length, Self.minimumRadius)
        case .across:
            let p = position(of: .across)
            let q = local(CGPoint(x: p.x + delta.dx, y: p.y + delta.dy))
            radii.height = max(abs(q.y), Self.minimumRadius)
        }
    }

    /// Its two axes, end to end, for drawing while it is edited.
    public var axes: [(CGPoint, CGPoint)] {
        [(world(CGPoint(x: -radii.width, y: 0)), world(CGPoint(x: radii.width, y: 0))),
         (world(CGPoint(x: 0, y: -radii.height)), world(CGPoint(x: 0, y: radii.height)))]
    }
}
