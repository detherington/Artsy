import Foundation

/// Pressure for a pen that reports none, a mouse or a finger: from how fast it moves.
/// Slow presses hard, a quick hatch lies light, as a hand does on paper.
///
/// The speed is the hand's, in screen points a second, not canvas pixels: a point is a
/// pixel or two on the Mac's canvas but five or six on a phone's, where every finger
/// stroke read as a sprint and came out light, and zooming in or out would change the
/// feel of the same motion. It is smoothed over a moment so the pressure does not
/// flicker from sample to sample. The landing sample counts as still, since the pen has
/// just landed, and so does a rest before it moves; the first movement sets the speed
/// outright rather than easing up from nothing, which gave every stroke a heavy head for
/// its first tenth of a second. The pressure curve applies on top, as it does to a real
/// pen's pressure, and a recording keeps the raw samples and the zoom, so a replay
/// derives the same pressure again.
public struct PressureFromSpeed {
    /// Screen points a second at which the touch is lightest.
    public static let fastSpeed: Float = 2500
    /// The pressure at full speed.
    public static let lightest: Float = 0.2
    /// How long the speed takes to follow a change, seconds.
    static let smoothing: TimeInterval = 0.08

    /// Screen points per canvas pixel: the zoom the stroke is drawn at.
    public var zoom: Float
    private var last: (position: CGPoint, time: TimeInterval)?
    private var speed: Float = 0
    /// Whether the pen has moved yet. Until it has, the speed is taken as it comes.
    private var moving = false

    public init(zoom: Float = 1) { self.zoom = zoom }

    /// The pressure for `point`, from its speed since the sample before.
    public mutating func pressure(for point: StrokePoint) -> Float {
        defer { last = (point.position, point.timestamp) }
        guard let last else { return 1 }
        let dt = point.timestamp - last.time
        guard dt > 0 else { return current }
        let distance = Float(hypot(point.position.x - last.position.x, point.position.y - last.position.y)) * zoom
        let now = distance / Float(dt)
        if moving {
            speed += (now - speed) * Float(1 - exp(-dt / Self.smoothing))
        } else {
            speed = now
            moving = distance > 0
        }
        return current
    }

    /// The pressure for the smoothed speed: full when still, `lightest` at `fastSpeed`,
    /// falling away faster at first.
    var current: Float {
        let t = min(1, max(0, speed / Self.fastSpeed))
        return Self.lightest + (1 - Self.lightest) * pow(1 - t, 1.5)
    }

    /// The pressure a steady speed gives, for the curve on its own.
    public static func pressure(atSpeed speed: Float) -> Float {
        var p = PressureFromSpeed()
        p.speed = speed
        return p.current
    }
}
