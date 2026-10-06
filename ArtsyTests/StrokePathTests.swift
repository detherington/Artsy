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
