import CoreGraphics
@testable import Artsy

/// Synthetic pen input for tests: deterministic strokes sampled at a tablet-like 200 Hz.
/// Coordinates are canvas-space (origin bottom-left, Y up).
enum StrokeFixtures {
    static let sampleRate = 200.0

    /// Sample `path(t)` for t in 0...1 over `duration` seconds.
    static func sampled(duration: Double, _ path: (Double) -> (CGPoint, Float)) -> [StrokePoint] {
        let count = max(2, Int(duration * sampleRate))
        return (0...count).map { i in
            let t = Double(i) / Double(count)
            let (position, pressure) = path(t)
            return StrokePoint(position: position, pressure: pressure, tiltX: 0, tiltY: 0,
                               rotation: 0, timestamp: t * duration)
        }
    }

    /// Straight line with pressure ramping linearly between the two values.
    static func line(from a: CGPoint, to b: CGPoint, pressure: ClosedRange<Float> = 0.7...0.7,
                     duration: Double = 0.5) -> [StrokePoint] {
        sampled(duration: duration) { t in
            (CGPoint(x: a.x + (b.x - a.x) * t, y: a.y + (b.y - a.y) * t),
             pressure.lowerBound + (pressure.upperBound - pressure.lowerBound) * Float(t))
        }
    }

    /// A pen tap: one sample.
    static func dot(at point: CGPoint, pressure: Float = 0.8) -> [StrokePoint] {
        [StrokePoint(position: point, pressure: pressure, tiltX: 0, tiltY: 0, rotation: 0, timestamp: 0)]
    }

    /// Sine wave along x, pressure swelling and fading along the way.
    static func wave(from start: CGPoint, length: CGFloat, amplitude: CGFloat, cycles: Double,
                     duration: Double = 0.8) -> [StrokePoint] {
        sampled(duration: duration) { t in
            (CGPoint(x: start.x + length * t, y: start.y + amplitude * sin(t * cycles * 2 * .pi)),
             Float(0.35 + 0.55 * sin(t * .pi)))
        }
    }

    /// Sharp corners: a sawtooth between `bottom` and `top`.
    static func zigzag(from start: CGPoint, length: CGFloat, height: CGFloat, teeth: Int,
                       pressure: Float = 0.8, duration: Double = 0.8) -> [StrokePoint] {
        sampled(duration: duration) { t in
            let phase = t * Double(teeth)
            let within = phase - phase.rounded(.down)
            let up = Int(phase) % 2 == 0
            return (CGPoint(x: start.x + length * t, y: start.y + height * (up ? within : 1 - within)), pressure)
        }
    }

    /// Spiral outwards — tight curvature at the centre, and the stroke passes close to itself.
    static func spiral(center: CGPoint, radius: ClosedRange<CGFloat>, turns: Double,
                       pressure: Float = 0.6, duration: Double = 1.0) -> [StrokePoint] {
        sampled(duration: duration) { t in
            let r = radius.lowerBound + (radius.upperBound - radius.lowerBound) * t
            let angle = t * turns * 2 * .pi
            return (CGPoint(x: center.x + r * cos(angle), y: center.y + r * sin(angle)), pressure)
        }
    }

    /// A line with hand tremor on top: pseudo-random jitter from a fixed seed.
    static func shaky(from a: CGPoint, to b: CGPoint, jitter: CGFloat, seed: UInt64 = 7,
                      duration: Double = 1.2) -> [StrokePoint] {
        var state = seed
        func next() -> CGFloat {
            state = state &* 6364136223846793005 &+ 1442695040888963407
            return CGFloat(state >> 40) / CGFloat(1 << 24) * 2 - 1
        }
        return sampled(duration: duration) { t in
            (CGPoint(x: a.x + (b.x - a.x) * t + next() * jitter,
                     y: a.y + (b.y - a.y) * t + 18 * sin(t * 3 * .pi) + next() * jitter),
             0.7)
        }
    }

    /// The standard sheet every brush is drawn with, for a 512×288 canvas: a pressure ramp,
    /// a wave, sharp corners with a line crossing them, a spiral, and two taps.
    static var brushSheet: [[StrokePoint]] {
        [
            line(from: CGPoint(x: 30, y: 250), to: CGPoint(x: 482, y: 250), pressure: 0.05...1.0, duration: 0.8),
            wave(from: CGPoint(x: 30, y: 185), length: 452, amplitude: 26, cycles: 3),
            zigzag(from: CGPoint(x: 30, y: 60), length: 270, height: 70, teeth: 7),
            line(from: CGPoint(x: 30, y: 95), to: CGPoint(x: 300, y: 95), pressure: 0.6...0.6),
            spiral(center: CGPoint(x: 395, y: 92), radius: 4...46, turns: 3.5),
            dot(at: CGPoint(x: 470, y: 130), pressure: 0.9),
            dot(at: CGPoint(x: 470, y: 50), pressure: 0.3),
        ]
    }
}
