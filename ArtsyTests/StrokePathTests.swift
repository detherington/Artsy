import XCTest
@testable import Artsy

final class StrokePathTests: XCTestCase {
    private let style = StrokePath.Style(brushSize: 20, pressureCurve: .linear,
                                         dynamics: BrushDescriptor.softRound.pressureDynamics)

    /// The renderer draws settled points once and never revisits them, so they must not move —
    /// including when the end of the stroke is being eased out behind the pen.
    func testSettledPointsNeverChange() {
        for easeLength in [CGFloat(0), 40] {
            var eased = style
            eased.easeLength = easeLength
            let path = StrokePath(style: eased)
            var settledSoFar: [InterpolatedPoint] = []

            for sample in StrokeFixtures.spiral(center: CGPoint(x: 100, y: 100), radius: 5...80, turns: 3) {
                path.append(sample)
                XCTAssertGreaterThanOrEqual(path.settledCount, settledSoFar.count)
                for (index, earlier) in settledSoFar.enumerated() {
                    XCTAssertEqual(path.points[index].position, earlier.position)
                    XCTAssertEqual(path.points[index].width, earlier.width)
                    XCTAssertEqual(path.points[index].opacity, earlier.opacity)
                }
                settledSoFar = Array(path.points[..<path.settledCount])
            }
            XCTAssertGreaterThan(path.settledCount, 100)
            XCTAssertLessThan(path.settledCount, path.points.count, "the newest part stays provisional")
        }
    }

    /// A long move followed by a short one makes a uniform Catmull-Rom spline overshoot the
    /// corner by several pixels. The centripetal form stays close to the samples.
    func testUnevenlySpacedSamplesDoNotOvershoot() {
        let corners = [CGPoint(x: 0, y: 0), CGPoint(x: 100, y: 0), CGPoint(x: 102, y: 2), CGPoint(x: 102, y: 100)]
        let path = StrokePath(style: style)
        for (index, corner) in corners.enumerated() {
            path.append(StrokePoint(position: corner, pressure: 0.6, tiltX: 0, tiltY: 0, rotation: 0,
                                    timestamp: Double(index) * 0.01))
        }
        XCTAssertGreaterThan(path.points.count, 150)
        for point in path.points {
            // Everything should stay inside the corner the samples turn through, give or
            // take the gentle bow of the long segments. (Uniform reaches x = 108.)
            XCTAssertLessThanOrEqual(point.position.x, 103.5, "overshoot past the corner at \(point.position)")
            XCTAssertGreaterThanOrEqual(point.position.y, -2.5, "overshoot past the corner at \(point.position)")
        }
    }

    /// With no pen pressure to shape it, a stroke eases in and out over `easeLength`.
    func testStrokeWithoutPressureEasesInAndOut() throws {
        var eased = style
        eased.easeLength = 30
        let dynamics = eased.dynamics
        let path = StrokePath(style: eased)
        StrokeFixtures.line(from: CGPoint(x: 10, y: 10), to: CGPoint(x: 210, y: 10), pressure: 0.7...0.7)
            .forEach(path.append)

        let full = dynamics.size(for: 0.7) * eased.brushSize
        let lightest = dynamics.size(for: 0) * eased.brushSize
        func width(atX x: CGFloat) -> Float {
            path.points.min { abs($0.position.x - x) < abs($1.position.x - x) }!.width
        }
        XCTAssertEqual(width(atX: 10), lightest, accuracy: 0.05, "starts at the brush's lightest touch")
        XCTAssertEqual(width(atX: 210), lightest, accuracy: 0.05, "and ends there")
        XCTAssertEqual(width(atX: 110), full, accuracy: 0.05, "full width in between")
        XCTAssertEqual(width(atX: 45), full, accuracy: 0.05, "reached within the ease length")
        XCTAssertLessThan(width(atX: 20), full)
        XCTAssertGreaterThan(width(atX: 20), lightest)
    }

    /// Easing must not make a click invisible or keep a short flick from reaching full width.
    func testEasingLeavesTapsAndShortStrokesVisible() {
        var eased = style
        eased.easeLength = 30
        let full = eased.dynamics.size(for: 0.7) * eased.brushSize

        let tap = StrokePath(style: eased)
        tap.append(StrokeFixtures.dot(at: CGPoint(x: 50, y: 50), pressure: 0.7)[0])
        XCTAssertEqual(tap.points[0].width, full, accuracy: 0.05)

        let flick = StrokePath(style: eased)
        StrokeFixtures.line(from: CGPoint(x: 10, y: 10), to: CGPoint(x: 30, y: 10), pressure: 0.7...0.7, duration: 0.05)
            .forEach(flick.append)
        XCTAssertEqual(flick.points.map(\.width).max()!, full, accuracy: 0.1, "a 20 px flick still peaks at full width")
    }

    func testPointsFollowTheSamplesAtAboutOnePixelSpacing() throws {
        let path = StrokePath(style: style)
        let samples = StrokeFixtures.line(from: CGPoint(x: 10, y: 10), to: CGPoint(x: 210, y: 10), pressure: 0.2...0.8)
        samples.forEach(path.append)

        let first = try XCTUnwrap(path.points.first), last = try XCTUnwrap(path.points.last)
        XCTAssertEqual(first.position.x, 10, accuracy: 0.001)
        XCTAssertEqual(last.position.x, 210, accuracy: 0.001)
        XCTAssertEqual(Double(path.points.count), 200, accuracy: 100, "roughly one point per pixel")
        // The spline is not arc-length parameterised, so spacing wanders a little around 1 px.
        for (a, b) in zip(path.points, path.points.dropFirst()) {
            XCTAssertLessThanOrEqual(hypot(b.position.x - a.position.x, b.position.y - a.position.y), 1.5)
        }
        XCTAssertLessThan(first.width, last.width, "pressure rises along the line")
    }

    func testATapIsOnePoint() {
        let path = StrokePath(style: style)
        path.append(StrokeFixtures.dot(at: CGPoint(x: 50, y: 50))[0])
        XCTAssertEqual(path.points.count, 1)
        XCTAssertEqual(path.settledCount, 0)
    }

    /// Pressing harder without moving grows the mark; easing off does not shrink it.
    func testPressureAloneGrowsTheMarkWhereThePenRests() {
        func sample(_ x: CGFloat, _ pressure: Float, _ t: Double) -> StrokePoint {
            StrokePoint(position: CGPoint(x: x, y: 50), pressure: pressure, tiltX: 0, tiltY: 0, rotation: 0, timestamp: t)
        }
        let path = StrokePath(style: style)
        path.append(sample(50, 0.1, 0))
        let lightWidth = path.points[0].width

        path.append(sample(50, 0.9, 0.01))
        XCTAssertEqual(path.points.count, 1)
        XCTAssertGreaterThan(path.points[0].width, lightWidth * 1.5)
        let firmWidth = path.points[0].width

        let revision = path.revision
        path.append(sample(50, 0.2, 0.02))
        XCTAssertEqual(path.points[0].width, firmWidth)
        XCTAssertEqual(path.revision, revision, "nothing changed, so nothing to redraw")

        // Same at the end of a longer stroke: the last point takes the firmer pressure.
        path.append(sample(60, 0.3, 0.03))
        path.append(sample(70, 0.3, 0.04))
        let settled = Array(path.points[..<path.settledCount])
        let endWidth = path.points.last!.width
        path.append(sample(70, 1.0, 0.05))
        XCTAssertGreaterThan(path.points.last!.width, endWidth)
        XCTAssertEqual(path.samples.count, 3)
        for (index, earlier) in settled.enumerated() {
            XCTAssertEqual(path.points[index].width, earlier.width)
        }
    }

    // MARK: - Dynamics

    private func line(tilt: SIMD2<Float> = .zero, rotation: Float = 0, speed: CGFloat = 400) -> [StrokePoint] {
        // 200 Hz samples along x at the given speed
        (0..<60).map { i in
            StrokePoint(position: CGPoint(x: CGFloat(i) * speed / 200, y: 50), pressure: 0.6,
                        tiltX: tilt.x, tiltY: tilt.y, rotation: rotation, timestamp: Double(i) / 200)
        }
    }

    func testLeaningThePenBroadensAndElongatesTheMark() {
        var pencil = style
        pencil.tilt = TiltDynamics(sizeScale: 2.5, opacityScale: 0.5, aspect: 2.0)

        let upright = StrokePath(style: pencil)
        line().forEach(upright.append)
        let flat = StrokePath(style: pencil)
        line(tilt: SIMD2(0, -0.95)).forEach(flat.append)
        let slight = StrokePath(style: pencil)
        line(tilt: SIMD2(0.1, 0)).forEach(slight.append)

        let up = upright.points[30], down = flat.points[30], bit = slight.points[30]
        XCTAssertEqual(down.width, up.width * 2.5, accuracy: 0.05)
        XCTAssertEqual(down.opacity, up.opacity * 0.5, accuracy: 0.01)
        XCTAssertEqual(down.aspect, 2.0, accuracy: 0.01)
        XCTAssertEqual(down.tiltAngle, -.pi / 2, accuracy: 0.01, "the long side follows the lean")
        XCTAssertEqual(up.aspect, 1)
        XCTAssertEqual(bit.width, up.width, accuracy: 0.001, "a normal grip's slight lean changes nothing")

        let plain = StrokePath(style: style)   // no tilt dynamics
        line(tilt: SIMD2(0, -0.95)).forEach(plain.append)
        XCTAssertEqual(plain.points[30].width, up.width, accuracy: 0.001)
    }

    func testASweptBrushThins() {
        var ink = style
        ink.velocity = VelocityDynamics(referenceSpeed: 1000, sizeScale: 0.5, opacityScale: 0.8)

        let slow = StrokePath(style: ink)
        line(speed: 100).forEach(slow.append)
        let fast = StrokePath(style: ink)
        line(speed: 1000).forEach(fast.append)
        let faster = StrokePath(style: ink)
        line(speed: 3000).forEach(faster.append)

        let rest = style.dynamics.size(for: PressureCurve.linear.map(0.6)) * style.brushSize
        XCTAssertEqual(slow.points.last!.width, rest * 0.95, accuracy: rest * 0.05)
        XCTAssertEqual(fast.points.last!.width, rest * 0.5, accuracy: rest * 0.03, "half as wide at the reference speed")
        XCTAssertEqual(faster.points.last!.width, rest * 0.5, accuracy: rest * 0.01, "and no thinner beyond it")
        XCTAssertEqual(fast.points.last!.opacity, slow.points.last!.opacity * 0.8, accuracy: 0.03)
        XCTAssertLessThan(fast.points[2].width, rest, "speed is smoothed in, not applied in one jump")
        XCTAssertGreaterThan(fast.points[2].width, fast.points.last!.width)
    }

    func testRestingIsTimedAndOnlyRedrawsWhenTheBrushSprays() {
        func sample(_ x: CGFloat, _ t: Double) -> StrokePoint {
            StrokePoint(position: CGPoint(x: x, y: 50), pressure: 0.5, tiltX: 0, tiltY: 0, rotation: 0, timestamp: t)
        }
        for sprays in [false, true] {
            var spraying = style
            spraying.spraysWhileResting = sprays
            let path = StrokePath(style: spraying)
            path.append(sample(0, 0))
            path.append(sample(10, 0.01))
            XCTAssertEqual(path.holdDuration, 0)

            let revision = path.revision
            path.append(sample(10, 0.3))
            path.append(sample(10, 0.75))
            XCTAssertEqual(path.holdDuration, 0.74, accuracy: 0.001, "rest is measured from when the pen stopped")
            XCTAssertEqual(path.revision != revision, sprays, "a resting pen is only a change for a brush that sprays")
            XCTAssertEqual(path.samples.count, 2, "resting adds no samples")

            path.append(sample(20, 0.8))
            XCTAssertEqual(path.holdDuration, 0, "moving ends the rest")
            XCTAssertEqual(path.rests, [StrokePath.Rest(sampleIndex: 1, duration: 0.74)], "but it is remembered")
            XCTAssertNil(path.currentRest)
            let resting = try! XCTUnwrap(path.pointIndex(forSample: 1))
            XCTAssertEqual(path.points[resting].position, CGPoint(x: 10, y: 50), "and where it happened")

            path.append(sample(30, 0.9))
            XCTAssertEqual(path.points[try! XCTUnwrap(path.pointIndex(forSample: 1))].position, CGPoint(x: 10, y: 50))
            XCTAssertEqual(path.points[try! XCTUnwrap(path.pointIndex(forSample: 3))].position, CGPoint(x: 30, y: 50))
        }
    }

    func testBarrelRotationReachesThePoints() {
        let path = StrokePath(style: style)
        line(rotation: 90).forEach(path.append)
        XCTAssertEqual(path.points[20].rotation, .pi / 2, accuracy: 0.001)
    }

    /// A pen held still reports the same position repeatedly; that must still leave a dot.
    func testAPenThatDoesNotMoveStillLeavesADot() {
        let path = StrokePath(style: style)
        for i in 0..<5 {
            path.append(StrokePoint(position: CGPoint(x: 50, y: 50), pressure: 0.6, tiltX: 0, tiltY: 0,
                                    rotation: 0, timestamp: Double(i) * 0.005))
        }
        XCTAssertEqual(path.points.count, 1)
        XCTAssertEqual(path.points[0].position, CGPoint(x: 50, y: 50))
    }
}
