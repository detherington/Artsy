import Foundation

/// Pressure for a pen that reports none, or a mouse: from how fast it moves. Slow presses
/// hard, a quick hatch lies light, as a hand does on paper. The speed is smoothed over a
/// moment so the pressure does not flicker from sample to sample, and the first sample
/// counts as slow, since the pen has just landed. The pressure curve applies on top, as
/// it does to a real pen's pressure, and a recording keeps the raw samples, so a replay
/// derives the same pressure again.
public struct PressureFromSpeed {
    /// Canvas pixels a second at which the touch is lightest.
    public static let fastSpeed: Float = 2500
    /// The pressure at full speed.
    public static let lightest: Float = 0.2
    /// How long the speed takes to follow a change, seconds.
    static let smoothing: TimeInterval = 0.08

    private var last: (position: CGPoint, time: TimeInterval)?
    private var speed: Float = 0

    public init() {}

    /// The pressure for `point`, from its speed since the sample before.
    public mutating func pressure(for point: StrokePoint) -> Float {
        defer { last = (point.position, point.timestamp) }
        guard let last else { return 1 }
        let dt = point.timestamp - last.time
        guard dt > 0 else { return current }
        let distance = Float(hypot(point.position.x - last.position.x, point.position.y - last.position.y))
        let now = distance / Float(dt)
        speed += (now - speed) * Float(1 - exp(-dt / Self.smoothing))
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
