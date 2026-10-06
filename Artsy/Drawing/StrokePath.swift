import Foundation

/// Turns pen samples into the closely spaced points the renderer draws, one sample at a time.
///
/// Points lie on Catmull-Rom segments between consecutive samples. A segment's shape depends
/// on the sample after it, so the newest segment is provisional and is rebuilt when the next
/// sample arrives. `points[..<settledCount]` never change again, which is what lets the
/// renderer draw each part of a stroke once instead of redrawing all of it every frame.
final class StrokePath {
    /// How pressure becomes width and opacity; fixed for the length of a stroke.
    struct Style {
        var brushSize: Float
        var pressureCurve: PressureCurve
        var dynamics: PressureDynamics
    }

    private(set) var points: [InterpolatedPoint] = []
    /// Number of leading `points` that are final.
    private(set) var settledCount = 0
    private(set) var samples: [StrokePoint] = []
    /// Goes up every time `points` changes.
    private(set) var revision = 0
    private let style: Style

    /// Distance between emitted points, in canvas pixels.
    private let stepDistance: CGFloat = 1.0

    init(style: Style) {
        self.style = style
    }

    func append(_ sample: StrokePoint) {
        if let last = samples.last,
           hypot(sample.position.x - last.position.x, sample.position.y - last.position.y) <= 0.01 {
            // The pen hasn't moved, only its pressure has. Keep the firmest pressure seen at
            // this spot: a mark can grow where the pen rests, but easing off doesn't shrink it.
            guard sample.pressure > last.pressure else { return }
            samples[samples.count - 1] = StrokePoint(
                position: last.position, pressure: sample.pressure,
                tiltX: sample.tiltX, tiltY: sample.tiltY, rotation: sample.rotation,
                timestamp: sample.timestamp
            )
        } else {
            samples.append(sample)
            // The segment before the newest one now has the sample after it: settle it.
            if samples.count >= 3 {
                points.removeSubrange(settledCount...)
                emitSegment(samples.count - 3)
                settledCount = points.count
            }
        }

        // Rebuild the provisional segment. Only its pressure and shape depend on the newest
        // sample; settled points use the newest sample's position alone, which is fixed.
        points.removeSubrange(settledCount...)
        if samples.count >= 2 {
            emitSegment(samples.count - 2)
        }
        // A tap, or a pen that hasn't moved yet, is still a dot.
        if points.isEmpty {
            points = [point(at: samples[0].position, rawPressure: samples[0].pressure, angle: 0)]
        }
        revision += 1
    }

    private func point(at position: CGPoint, rawPressure: Float, angle: Float) -> InterpolatedPoint {
        let mapped = style.pressureCurve.map(rawPressure)
        return InterpolatedPoint(
            position: position,
            pressure: mapped,
            width: style.dynamics.size(for: mapped) * style.brushSize,
            opacity: style.dynamics.opacity(for: mapped),
            angle: angle
        )
    }

    /// Append the points of the segment from `samples[i]` to `samples[i + 1]`.
    private func emitSegment(_ i: Int) {
        let last = samples.count - 1
        let p0 = samples[max(0, i - 1)]
        let p1 = samples[i]
        let p2 = samples[min(last, i + 1)]
        let p3 = samples[min(last, i + 2)]

        let segLen = hypot(p2.position.x - p1.position.x, p2.position.y - p1.position.y)
        guard segLen > 0.01 else { return }

        let numSteps = max(1, Int(ceil(segLen / stepDistance)))
        let dt = 1.0 / CGFloat(numSteps)

        // The segment's first point is the previous segment's last, already emitted.
        let startStep = points.isEmpty ? 0 : 1
        for step in startStep...numSteps {
            let t = CGFloat(step) * dt
            let pos = catmullRom(t: t, p0: p0.position, p1: p1.position, p2: p2.position, p3: p3.position)
            let tangent = catmullRomTangent(t: t, p0: p0.position, p1: p1.position, p2: p2.position, p3: p3.position)
            points.append(point(
                at: pos,
                rawPressure: p1.pressure + Float(t) * (p2.pressure - p1.pressure),
                angle: Float(atan2(tangent.y, tangent.x))
            ))
        }
    }

    // MARK: - Catmull-Rom

    private func catmullRom(t: CGFloat, p0: CGPoint, p1: CGPoint, p2: CGPoint, p3: CGPoint) -> CGPoint {
        let t2 = t * t
        let t3 = t2 * t

        let x = 0.5 * ((2 * p1.x) +
            (-p0.x + p2.x) * t +
            (2 * p0.x - 5 * p1.x + 4 * p2.x - p3.x) * t2 +
            (-p0.x + 3 * p1.x - 3 * p2.x + p3.x) * t3)

        let y = 0.5 * ((2 * p1.y) +
            (-p0.y + p2.y) * t +
            (2 * p0.y - 5 * p1.y + 4 * p2.y - p3.y) * t2 +
            (-p0.y + 3 * p1.y - 3 * p2.y + p3.y) * t3)

        return CGPoint(x: x, y: y)
    }

    private func catmullRomTangent(t: CGFloat, p0: CGPoint, p1: CGPoint, p2: CGPoint, p3: CGPoint) -> CGPoint {
        let t2 = t * t

        let dx = 0.5 * ((-p0.x + p2.x) +
            2 * (2 * p0.x - 5 * p1.x + 4 * p2.x - p3.x) * t +
            3 * (-p0.x + 3 * p1.x - 3 * p2.x + p3.x) * t2)

        let dy = 0.5 * ((-p0.y + p2.y) +
            2 * (2 * p0.y - 5 * p1.y + 4 * p2.y - p3.y) * t +
            3 * (-p0.y + 3 * p1.y - 3 * p2.y + p3.y) * t2)

        return CGPoint(x: dx, y: dy)
    }
}
