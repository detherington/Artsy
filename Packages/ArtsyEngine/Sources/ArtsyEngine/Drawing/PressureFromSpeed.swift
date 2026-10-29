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
///
/// A pen without a force sensor (the USB-C Apple Pencil) is held like a pen and moves at a
/// pen's pace, two or three times a finger's, so it has a `Pace` of its own: lightest at a
/// higher speed and never below half, so quick handwriting keeps its weight where a finger
/// at the same speed would lie light.
public struct PressureFromSpeed {
    /// How fast an input is at its lightest, and how light that is: a finger drags, a pen flies.
    public struct Pace: Equatable {
        /// Screen points a second at which the touch is lightest.
        public var fastSpeed: Float
        /// The pressure at full speed.
        public var lightest: Float

        public init(fastSpeed: Float, lightest: Float) {
            self.fastSpeed = fastSpeed
            self.lightest = lightest
        }

        /// A finger, a mouse or a trackpad.
        public static let hand = Pace(fastSpeed: 2500, lightest: 0.2)
        /// A pen without a force sensor.
        public static let pen = Pace(fastSpeed: 4000, lightest: 0.5)
    }

    /// Screen points a second at which a hand is lightest.
    public static let fastSpeed: Float = Pace.hand.fastSpeed
    /// A hand's pressure at full speed.
    public static let lightest: Float = Pace.hand.lightest
    /// How long the speed takes to follow a change, seconds.
    static let smoothing: TimeInterval = 0.08

    /// Screen points per canvas pixel: the zoom the stroke is drawn at.
    public var zoom: Float
    /// Whose speed this is, a hand's or a pen's.
    public let pace: Pace
    private var last: (position: CGPoint, time: TimeInterval)?
    private var speed: Float = 0
    /// Whether the pen has moved yet. Until it has, the speed is taken as it comes.
    private var moving = false

    public init(zoom: Float = 1, pace: Pace = .hand) {
        self.zoom = zoom
        self.pace = pace
    }

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

    /// The pressure for the smoothed speed: full when still, the pace's `lightest` at its
    /// `fastSpeed`, falling away faster at first.
    var current: Float {
        let t = min(1, max(0, speed / pace.fastSpeed))
        return pace.lightest + (1 - pace.lightest) * pow(1 - t, 1.5)
    }

    /// The pressure a hand's steady speed gives, for the curve on its own.
    public static func pressure(atSpeed speed: Float) -> Float { pressure(atSpeed: speed, pace: .hand) }

    /// The pressure a steady speed gives at a pace, for the curve on its own.
    public static func pressure(atSpeed speed: Float, pace: Pace) -> Float {
        var p = PressureFromSpeed(pace: pace)
        p.speed = speed
        return p.current
    }
}
