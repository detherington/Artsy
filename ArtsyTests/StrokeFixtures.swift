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

    /// `points` followed by `seconds` of the pen resting on the last one, sampled at 120 Hz:
    /// what a hold at the end of a stroke looks like to the engine.
    static func held(_ points: [StrokePoint], for seconds: Double) -> [StrokePoint] {
        guard let last = points.last else { return points }
        let rests = (1...max(1, Int(seconds * 120))).map { i in
            StrokePoint(position: last.position, pressure: last.pressure, tiltX: last.tiltX, tiltY: last.tiltY,
                        rotation: last.rotation, timestamp: last.timestamp + Double(i) / 120)
        }
        return points + rests
    }

    /// A hand-drawn version of `ideal` (positions around a shape, open or closed): slow
    /// wobble of about `wobble` pixels, from a fixed seed.
    static func rough(_ ideal: [CGPoint], wobble: CGFloat, seed: UInt64 = 3, pressure: Float = 0.7,
                      duration: Double = 1.0) -> [StrokePoint] {
        var state = seed
        func next() -> CGFloat {
            state = state &* 6364136223846793005 &+ 1442695040888963407
            return CGFloat(state >> 40) / CGFloat(1 << 24) * 2 - 1
        }
        let phases = (0..<4).map { _ in next() * .pi }
        let count = ideal.count
        return ideal.enumerated().map { i, p in
            let t = Double(i) / Double(count)
            // Slow drift and a tremor; at a pen's sample rate the tremor spans many samples
            let dx = wobble * (0.6 * sin(t * 5 * .pi + phases[0]) + 0.4 * sin(t * 11 * .pi + phases[1]))
            let dy = wobble * (0.6 * sin(t * 4 * .pi + phases[2]) + 0.4 * sin(t * 13 * .pi + phases[3]))
            return StrokePoint(position: CGPoint(x: p.x + dx, y: p.y + dy), pressure: pressure,
                               tiltX: 0, tiltY: 0, rotation: 0, timestamp: t * duration)
        }
    }

    /// Positions around an ideal circle, 3 px apart, starting at the top.
    static func circlePositions(center: CGPoint, radius: CGFloat) -> [CGPoint] {
        let count = max(24, Int(2 * .pi * radius / 3))
        return (0...count).map { i in
            let a = CGFloat(i) / CGFloat(count) * 2 * .pi + .pi / 2
            return CGPoint(x: center.x + radius * cos(a), y: center.y + radius * sin(a))
        }
    }

    /// Positions around a polygon, 3 px apart, back to the first corner.
    static func polygonPositions(_ corners: [CGPoint]) -> [CGPoint] {
        var result: [CGPoint] = []
        for (i, a) in corners.enumerated() {
            let b = corners[(i + 1) % corners.count]
            let steps = max(1, Int(hypot(b.x - a.x, b.y - a.y) / 3))
            for s in 0..<steps {
                let t = CGFloat(s) / CGFloat(steps)
                result.append(CGPoint(x: a.x + (b.x - a.x) * t, y: a.y + (b.y - a.y) * t))
            }
        }
        result.append(corners[0])
        return result
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
