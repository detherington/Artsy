import XCTest
@testable import Artsy

final class StrokePathTests: XCTestCase {
    private let style = StrokePath.Style(brushSize: 20, pressureCurve: .linear,
                                         dynamics: BrushDescriptor.softRound.pressureDynamics)

    /// The renderer draws settled points once and never revisits them, so they must not move.
    func testSettledPointsNeverChange() {
        let path = StrokePath(style: style)
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
        XCTAssertLessThan(path.settledCount, path.points.count, "the newest segment stays provisional")
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
