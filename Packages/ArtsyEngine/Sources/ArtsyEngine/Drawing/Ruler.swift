import CoreGraphics
import Foundation

/// What the drawing guides share: perspective, the ruler and the ellipse template, each
/// moved by handles in an editor of its own and able to hold a stroke. Speed and focus
/// lines being laid out are edited the same way, by their clear area's handles, though
/// they hold no stroke and are made into a layer rather than kept.
public enum DrawingGuide: Equatable {
    case perspective
    case ruler
    case ellipse
    /// Speed or focus lines being laid out (`CanvasViewModel.comicLines`).
    case lines

    /// How near a press has to come to a handle to pick it up, in screen points.
    public static let handleReach: CGFloat = 24
    /// How near its edge a stroke has to land for a ruler or an ellipse to take it, in
    /// screen points.
    public static let strokeReach: CGFloat = 16
}

/// A ruler laid on the canvas: a straight edge from one point to another. A stroke laid
/// against it runs along its line (see `HeldStroke`). Canvas pixels, y up, as the guides are.
public struct RulerGuide: Codable, Equatable {
    public var start: CGPoint
    public var end: CGPoint
    public var isShown = true
    /// Whether strokes laid against it run along it.
    public var snaps = true

    public init(start: CGPoint, end: CGPoint) {
        self.start = start
        self.end = end
    }

    public var length: CGFloat { hypot(end.x - start.x, end.y - start.y) }
    public var middle: CGPoint { CGPoint(x: (start.x + end.x) / 2, y: (start.y + end.y) / 2) }

    /// Shown, snapping and with some length: whether it can hold a stroke.
    public var holdsStrokes: Bool { isShown && snaps && length > 1e-3 }

    /// Its direction, a unit vector from start to end; level for one with no length.
    public var direction: CGVector {
        let l = length
        guard l > 1e-6 else { return CGVector(dx: 1, dy: 0) }
        return CGVector(dx: (end.x - start.x) / l, dy: (end.y - start.y) / l)
    }

    /// Its angle on the canvas in degrees, from 0 (level) up to 180, a line having no way
    /// round: 90 is upright.
    public var angle: CGFloat {
        var degrees = atan2(end.y - start.y, end.x - start.x) * 180 / .pi
        while degrees < 0 { degrees += 180 }
        while degrees >= 180 { degrees -= 180 }
        // Just under 180 reads as level
        return degrees > 179.95 ? 0 : degrees
    }

    /// `point` moved square onto the ruler's line, past its ends too.
    public func projected(_ point: CGPoint) -> CGPoint {
        let d = direction
        let along = (point.x - start.x) * d.dx + (point.y - start.y) * d.dy
        return CGPoint(x: start.x + d.dx * along, y: start.y + d.dy * along)
    }

    /// How far `point` is from the ruler itself, between its ends.
    public func distance(to point: CGPoint) -> CGFloat {
        let l = length
        guard l > 1e-6 else { return hypot(point.x - start.x, point.y - start.y) }
        let d = direction
        let along = min(max((point.x - start.x) * d.dx + (point.y - start.y) * d.dy, 0), l)
        return hypot(point.x - (start.x + d.dx * along), point.y - (start.y + d.dy * along))
    }

    // MARK: - Handles

    /// What a press can pick up while the ruler is edited.
    public enum Handle: Equatable {
        case start
        case end
        /// The whole ruler.
        case middle
    }

    public func position(of handle: Handle) -> CGPoint {
        switch handle {
        case .start: return start
        case .end: return end
        case .middle: return middle
        }
    }

    /// The handle within `reach` canvas pixels of `point`, the nearest if more than one.
    public func handle(near point: CGPoint, reach: CGFloat) -> Handle? {
        [Handle.start, .end, .middle]
            .map { ($0, hypot(position(of: $0).x - point.x, position(of: $0).y - point.y)) }
            .filter { $0.1 <= reach }
            .min { $0.1 < $1.1 }?.0
    }

    /// `handle` moved by `delta`: an end on its own, or the whole ruler by its middle.
    public mutating func move(_ handle: Handle, by delta: CGVector) {
        switch handle {
        case .start:
            start.x += delta.dx; start.y += delta.dy
        case .end:
            end.x += delta.dx; end.y += delta.dy
        case .middle:
            start.x += delta.dx; start.y += delta.dy
            end.x += delta.dx; end.y += delta.dy
        }
    }

    /// Turned about its middle to the nearest 15°, its length kept.
    public mutating func straighten() {
        let turned = Self.nearestStep(atan2(end.y - start.y, end.x - start.x))
        let m = middle, half = length / 2
        start = CGPoint(x: m.x - cos(turned) * half, y: m.y - sin(turned) * half)
        end = CGPoint(x: m.x + cos(turned) * half, y: m.y + sin(turned) * half)
    }

    /// `radians` to the nearest 15°.
    static func nearestStep(_ radians: CGFloat) -> CGFloat {
        let step = CGFloat.pi / 12
        return (radians / step).rounded() * step
    }
}
