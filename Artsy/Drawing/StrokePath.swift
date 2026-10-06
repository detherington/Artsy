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
        var tilt: TiltDynamics? = nil
        var velocity: VelocityDynamics? = nil
        /// True when the brush lays dabs while the pen rests, so resting has to count as
        /// a change worth redrawing.
        var spraysWhileResting = false
        /// For input with no pressure of its own (a mouse): the distance over which pressure
        /// eases in from nothing at the start of the stroke and back out at its end, as if a
        /// pen were touching down and lifting off. 0 turns it off.
        var easeLength: CGFloat = 0
    }

    private(set) var points: [InterpolatedPoint] = []
    /// Number of leading `points` that are final.
    private(set) var settledCount = 0
    private(set) var samples: [StrokePoint] = []
    /// Goes up every time `points` changes.
    private(set) var revision = 0
    /// How long the pen has rested at the end of the stroke, in seconds.
    private(set) var holdDuration: TimeInterval = 0
    private var restingSince: TimeInterval = 0
    private let style: Style

    /// A pause with the pen down.
    struct Rest: Equatable {
        /// The sample the pen rested on.
        let sampleIndex: Int
        let duration: TimeInterval
    }
    /// Rests the pen has already moved on from, oldest first.
    private(set) var rests: [Rest] = []
    /// The rest in progress at the end of the stroke, if the pen is resting.
    var currentRest: Rest? {
        holdDuration > 0 ? Rest(sampleIndex: samples.count - 1, duration: holdDuration) : nil
    }
    /// For each sample, the index of the point that sits exactly on it.
    private var samplePointIndex: [Int] = []

    /// The point that sits on `samples[sampleIndex]`.
    func pointIndex(forSample sampleIndex: Int) -> Int? {
        guard sampleIndex < samplePointIndex.count, samplePointIndex[sampleIndex] < points.count else { return nil }
        return samplePointIndex[sampleIndex]
    }

    /// A point before pressure is turned into width and opacity.
    private struct Base {
        var position: CGPoint
        var rawPressure: Float
        var angle: Float
        /// Path length from the start of the stroke to this point.
        var distance: CGFloat
        var tilt: SIMD2<Float>
        var rotation: Float
        /// Canvas pixels per second, smoothed.
        var speed: Float
    }
    private var base: [Base] = []
    /// Smoothed speed at each sample, so a jittery clock doesn't flicker the width.
    private var speeds: [Float] = []
    /// Number of leading `base` points that come from settled segments.
    private var settledBaseCount = 0

    /// Distance between emitted points, in canvas pixels.
    private let stepDistance: CGFloat = 1.0

    init(style: Style) {
        self.style = style
    }

    func append(_ sample: StrokePoint) {
        if let last = samples.last,
           hypot(sample.position.x - last.position.x, sample.position.y - last.position.y) <= 0.01 {
            // The pen hasn't moved. Count the rest, and keep the firmest pressure seen at
            // this spot: a mark can grow where the pen rests, but easing off doesn't shrink it.
            holdDuration = max(0, sample.timestamp - restingSince)
            guard sample.pressure > last.pressure else {
                if style.spraysWhileResting { revision += 1 }
                return
            }
            samples[samples.count - 1] = StrokePoint(
                position: last.position, pressure: sample.pressure,
                tiltX: sample.tiltX, tiltY: sample.tiltY, rotation: sample.rotation,
                timestamp: sample.timestamp
            )
        } else {
            if holdDuration > 0 {
                rests.append(Rest(sampleIndex: samples.count - 1, duration: holdDuration))
            }
            restingSince = sample.timestamp
            holdDuration = 0
            if let last = samples.last {
                let dt = Float(max(sample.timestamp - last.timestamp, 0.0005))
                let instantaneous = Float(hypot(sample.position.x - last.position.x, sample.position.y - last.position.y)) / dt
                let previous = speeds[speeds.count - 1]
                speeds.append(previous + (instantaneous - previous) * dt / (dt + 0.04))
            } else {
                speeds.append(0)
            }
            samples.append(sample)
            samplePointIndex.append(0)
            // The segment before the newest one now has the sample after it: settle it.
            if samples.count >= 3 {
                base.removeSubrange(settledBaseCount...)
                emitSegment(samples.count - 3)
                samplePointIndex[samples.count - 2] = base.count - 1
                settledBaseCount = base.count
            }
        }

        // Rebuild the provisional segment. Only its pressure and shape depend on the newest
        // sample; settled segments use the newest sample's position alone, which is fixed.
        base.removeSubrange(settledBaseCount...)
        if samples.count >= 2 {
            emitSegment(samples.count - 2)
        }
        // A tap, or a pen that hasn't moved yet, is still a dot.
        if base.isEmpty {
            base = [Base(position: samples[0].position, rawPressure: samples[0].pressure, angle: 0, distance: 0,
                         tilt: SIMD2(samples[0].tiltX, samples[0].tiltY), rotation: samples[0].rotation, speed: 0)]
        }
        // Each segment ends exactly on its sample, so the newest sample sits on the last point.
        samplePointIndex[samples.count - 1] = base.count - 1

        resolvePoints()
        revision += 1
    }

    // MARK: - Pressure to width and opacity

    /// Rebuild `points` from `base` for everything that isn't settled yet, and advance
    /// `settledCount` as far as it can go.
    private func resolvePoints() {
        let total = base[base.count - 1].distance
        // Short strokes ease over half their length each way, so their middle still
        // reaches full pressure and a tap (no length at all) is not eased away.
        let ease = min(style.easeLength, total / 2)

        points.removeSubrange(settledCount...)
        for index in settledCount..<base.count {
            let b = base[index]
            var pressure = b.rawPressure
            if ease > 0 {
                let t = Float(min(1, min(b.distance, total - b.distance) / ease))
                pressure *= t * t * (3 - 2 * t)
            }
            let mapped = style.pressureCurve.map(pressure)
            var width = style.dynamics.size(for: mapped) * style.brushSize
            var opacity = style.dynamics.opacity(for: mapped)
            var aspect: Float = 1
            if let tilt = style.tilt {
                let lean = TiltDynamics.amount(of: b.tilt)
                width *= 1 + (tilt.sizeScale - 1) * lean
                opacity *= 1 + (tilt.opacityScale - 1) * lean
                aspect = 1 + (tilt.aspect - 1) * lean
            }
            if let velocity = style.velocity {
                let speed = velocity.amount(atSpeed: b.speed)
                width *= 1 + (velocity.sizeScale - 1) * speed
                opacity *= 1 + (velocity.opacityScale - 1) * speed
            }
            points.append(InterpolatedPoint(
                position: b.position,
                pressure: mapped,
                width: width,
                opacity: opacity,
                angle: b.angle,
                distance: b.distance,
                aspect: aspect,
                tiltAngle: atan2(b.tilt.y, b.tilt.x),
                rotation: b.rotation * .pi / 180
            ))
        }

        if style.easeLength <= 0 {
            settledCount = settledBaseCount
        } else if total >= style.easeLength * 2 {
            // The ease-out trails the end of the stroke, so only points further back than
            // that are final — and only once the stroke is long enough that the ease-in
            // has stopped stretching.
            let limit = total - style.easeLength
            var count = settledCount
            while count < settledBaseCount, base[count].distance <= limit { count += 1 }
            settledCount = count
        }
    }

    // MARK: - Geometry

    /// Append the points of the segment from `samples[i]` to `samples[i + 1]`.
    private func emitSegment(_ i: Int) {
        let last = samples.count - 1
        let p0 = samples[max(0, i - 1)].position
        let p1 = samples[i]
        let p2 = samples[min(last, i + 1)]
        let p3 = samples[min(last, i + 2)].position
        let speed1 = speeds[i], speed2 = speeds[min(last, i + 1)]

        let segLen = hypot(p2.position.x - p1.position.x, p2.position.y - p1.position.y)
        guard segLen > 0.01 else { return }

        let (m1, m2) = centripetalTangents(p0: p0, p1: p1.position, p2: p2.position, p3: p3)
        let numSteps = max(1, Int(ceil(segLen / stepDistance)))
        let dt = 1.0 / CGFloat(numSteps)

        // The segment's first point is the previous segment's last, already emitted.
        let startStep = base.isEmpty ? 0 : 1
        for step in startStep...numSteps {
            let t = CGFloat(step) * dt
            let pos = hermite(t: t, p1: p1.position, m1: m1, p2: p2.position, m2: m2)
            let tangent = hermiteTangent(t: t, p1: p1.position, m1: m1, p2: p2.position, m2: m2)
            let distance = base.last.map { $0.distance + hypot(pos.x - $0.position.x, pos.y - $0.position.y) } ?? 0
            let ft = Float(t)
            base.append(Base(
                position: pos,
                rawPressure: p1.pressure + ft * (p2.pressure - p1.pressure),
                angle: Float(atan2(tangent.y, tangent.x)),
                distance: distance,
                tilt: SIMD2(p1.tiltX + ft * (p2.tiltX - p1.tiltX), p1.tiltY + ft * (p2.tiltY - p1.tiltY)),
                rotation: p1.rotation + ft * (p2.rotation - p1.rotation),
                speed: speed1 + ft * (speed2 - speed1)
            ))
        }
    }

    /// Tangents at `p1` and `p2` for a centripetal Catmull-Rom segment, scaled for a Hermite
    /// curve over t in 0...1.
    ///
    /// Centripetal spacing (knot intervals of √distance) keeps the curve from overshooting or
    /// looping when samples are unevenly spaced — a long move followed by a short one — which
    /// the uniform form does. With evenly spaced samples the two are identical.
    private func centripetalTangents(p0: CGPoint, p1: CGPoint, p2: CGPoint, p3: CGPoint) -> (CGPoint, CGPoint) {
        func knot(_ a: CGPoint, _ b: CGPoint) -> CGFloat { sqrt(hypot(b.x - a.x, b.y - a.y)) }
        let d01 = knot(p0, p1), d12 = knot(p1, p2), d23 = knot(p2, p3)
        let chord = CGPoint(x: p2.x - p1.x, y: p2.y - p1.y)

        // At either end of the stroke there is no neighbour (it repeats the end sample):
        // head straight along the chord.
        func tangent(_ a: CGPoint, _ b: CGPoint, _ c: CGPoint, dab: CGFloat, dbc: CGFloat) -> CGPoint {
            guard dab > 1e-4, dbc > 1e-4 else { return chord }
            let x = (b.x - a.x) / dab - (c.x - a.x) / (dab + dbc) + (c.x - b.x) / dbc
            let y = (b.y - a.y) / dab - (c.y - a.y) / (dab + dbc) + (c.y - b.y) / dbc
            return CGPoint(x: x * d12, y: y * d12)
        }
        return (tangent(p0, p1, p2, dab: d01, dbc: d12), tangent(p1, p2, p3, dab: d12, dbc: d23))
    }

    private func hermite(t: CGFloat, p1: CGPoint, m1: CGPoint, p2: CGPoint, m2: CGPoint) -> CGPoint {
        let t2 = t * t
        let t3 = t2 * t
        let h00 = 2 * t3 - 3 * t2 + 1
        let h10 = t3 - 2 * t2 + t
        let h01 = -2 * t3 + 3 * t2
        let h11 = t3 - t2
        return CGPoint(x: h00 * p1.x + h10 * m1.x + h01 * p2.x + h11 * m2.x,
                       y: h00 * p1.y + h10 * m1.y + h01 * p2.y + h11 * m2.y)
    }

    private func hermiteTangent(t: CGFloat, p1: CGPoint, m1: CGPoint, p2: CGPoint, m2: CGPoint) -> CGPoint {
        let t2 = t * t
        let h00 = 6 * t2 - 6 * t
        let h10 = 3 * t2 - 4 * t + 1
        let h01 = -6 * t2 + 6 * t
        let h11 = 3 * t2 - 2 * t
        return CGPoint(x: h00 * p1.x + h10 * m1.x + h01 * p2.x + h11 * m2.x,
                       y: h00 * p1.y + h10 * m1.y + h01 * p2.y + h11 * m2.y)
    }
}
