import XCTest
@testable import Artsy

/// Hold the pen still at the end of a rough stroke and it snaps to the shape it was going for.
final class ShapeSnapTests: XCTestCase {
    private let ink = StrokeColor(red: 0.1, green: 0.3, blue: 0.7, alpha: 1)

    // MARK: - Recognising shapes

    func testRecognisesALine() {
        let shaky = StrokeFixtures.rough((0...60).map { CGPoint(x: 20 + CGFloat($0) * 5, y: 100 + CGFloat($0) * 1.5) }, wobble: 5)
        guard case .line(let from, let to)? = ShapeRecognizer.recognize(shaky.map(\.position)) else {
            return XCTFail("a wobbly line should be a line")
        }
        XCTAssertEqual(from.x, 20, accuracy: 6)
        XCTAssertEqual(to.x, 320, accuracy: 6)
        XCTAssertEqual(to.y, 190, accuracy: 6)
    }

    func testRecognisesACircleAndAnEllipse() {
        let circle = StrokeFixtures.rough(StrokeFixtures.circlePositions(center: CGPoint(x: 200, y: 150), radius: 80), wobble: 8)
        guard case .ellipse(let center, let radii, _)? = ShapeRecognizer.recognize(circle.map(\.position)) else {
            return XCTFail("a wobbly circle should be a circle")
        }
        XCTAssertEqual(center.x, 200, accuracy: 4)
        XCTAssertEqual(center.y, 150, accuracy: 4)
        XCTAssertEqual(radii.width, 80, accuracy: 5)
        XCTAssertEqual(radii.width, radii.height, "a circle: equal radii")
        XCTAssertEqual(ShapeRecognizer.recognize(circle.map(\.position))?.name, "Circle")

        let ellipse = (0...200).map { i -> CGPoint in
            let t = CGFloat(i) / 200 * 2 * .pi
            return CGPoint(x: 200 + 120 * cos(t), y: 150 + 50 * sin(t))
        }
        guard case .ellipse(_, let eRadii, let angle)? = ShapeRecognizer.recognize(StrokeFixtures.rough(ellipse, wobble: 6).map(\.position)) else {
            return XCTFail("a wobbly ellipse should be an ellipse")
        }
        XCTAssertEqual(max(eRadii.width, eRadii.height), 120, accuracy: 8)
        XCTAssertEqual(min(eRadii.width, eRadii.height), 50, accuracy: 8)
        XCTAssertEqual(abs(sin(angle)), 0, accuracy: 0.1, "lying flat")
    }

    func testRecognisesARectangleAndATriangle() {
        let box = StrokeFixtures.polygonPositions([CGPoint(x: 100, y: 100), CGPoint(x: 300, y: 100),
                                                   CGPoint(x: 300, y: 220), CGPoint(x: 100, y: 220)])
        guard case .polygon(let corners)? = ShapeRecognizer.recognize(StrokeFixtures.rough(box, wobble: 6).map(\.position)) else {
            return XCTFail("a wobbly box should be a rectangle")
        }
        XCTAssertEqual(corners.count, 4)
        XCTAssertTrue(RecognizedShape.isRectangle(corners))
        let xs = corners.map(\.x), ys = corners.map(\.y)
        XCTAssertEqual(xs.min()!, 100, accuracy: 8)
        XCTAssertEqual(xs.max()!, 300, accuracy: 8)
        XCTAssertEqual(ys.min()!, 100, accuracy: 8)
        XCTAssertEqual(ys.max()!, 220, accuracy: 8)
        XCTAssertEqual(corners[0].y, corners[1].y, accuracy: 0.01, "squared up to the axes")

        let triangle = StrokeFixtures.polygonPositions([CGPoint(x: 100, y: 80), CGPoint(x: 320, y: 100), CGPoint(x: 200, y: 260)])
        guard case .polygon(let tri)? = ShapeRecognizer.recognize(StrokeFixtures.rough(triangle, wobble: 5).map(\.position)) else {
            return XCTFail("a wobbly triangle should be a triangle")
        }
        XCTAssertEqual(tri.count, 3)
        XCTAssertEqual(ShapeRecognizer.recognize(StrokeFixtures.rough(triangle, wobble: 5).map(\.position))?.name, "Triangle")
    }

    /// The four rough shapes of the `shape-snap` golden, as the golden draws them.
    func testTheGoldenSheetsShapesAreAllRecognised() {
        let shapes: [(name: String, ideal: [CGPoint])] = [
            ("Circle", StrokeFixtures.circlePositions(center: CGPoint(x: 100, y: 190), radius: 60)),
            ("Rectangle", StrokeFixtures.polygonPositions([CGPoint(x: 200, y: 130), CGPoint(x: 340, y: 140),
                                                           CGPoint(x: 335, y: 250), CGPoint(x: 195, y: 240)])),
            ("Line", (0...80).map { CGPoint(x: 380 + CGFloat($0) * 1.3, y: 120 + CGFloat($0) * 1.8) }),
            ("Triangle", StrokeFixtures.polygonPositions([CGPoint(x: 60, y: 30), CGPoint(x: 240, y: 40), CGPoint(x: 150, y: 110)])),
        ]
        for (index, shape) in shapes.enumerated() {
            let positions = StrokeFixtures.rough(shape.ideal, wobble: 8, seed: UInt64(index + 1)).map(\.position)
            let first = positions.first!, last = positions.last!
            let chord = hypot(last.x - first.x, last.y - first.y)
            let length = zip(positions, positions.dropFirst()).reduce(CGFloat(0)) { $0 + hypot($1.1.x - $1.0.x, $1.1.y - $1.0.y) }
            XCTAssertEqual(ShapeRecognizer.recognize(positions)?.name, shape.name,
                           "\(shape.name): chord \(Int(chord)) of length \(Int(length))")
        }
    }

    /// Most strokes are not shapes, and must be left alone.
    func testLeavesOrdinaryStrokesAlone() {
        let wave = StrokeFixtures.wave(from: CGPoint(x: 20, y: 100), length: 300, amplitude: 40, cycles: 2)
        XCTAssertNil(ShapeRecognizer.recognize(wave.map(\.position)), "a wave")
        let spiral = StrokeFixtures.spiral(center: CGPoint(x: 200, y: 150), radius: 10...90, turns: 2.5)
        XCTAssertNil(ShapeRecognizer.recognize(spiral.map(\.position)), "a spiral")
        let bentLine = StrokeFixtures.sampled(duration: 1) { t in
            (CGPoint(x: 20 + 300 * t, y: 100 + 60 * sin(t * .pi)), 0.7)
        }
        XCTAssertNil(ShapeRecognizer.recognize(bentLine.map(\.position)), "an arc is not straight enough")
        XCTAssertNil(ShapeRecognizer.recognize(StrokeFixtures.dot(at: CGPoint(x: 50, y: 50)).map(\.position)), "a tap")
    }

    // MARK: - Snapping while drawing

    private func canvas() throws -> EngineHarness {
        let harness = try EngineHarness(width: 400, height: 300)
        harness.select(.hardRound)
        harness.viewModel.brushSize = 8
        harness.viewModel.currentColor = ink
        return harness
    }

    private func onTheCircle(_ layer: PixelGrid, center: CGPoint, radius: CGFloat) -> [Float] {
        stride(from: 0.0, to: 360, by: 30).map { degrees in
            let a = CGFloat(degrees) * .pi / 180
            return layer.at(x: Int((center.x + radius * cos(a)).rounded()), y: Int((center.y + radius * sin(a)).rounded())).w
        }
    }

    func testAHeldRoughCircleBecomesACircle() throws {
        let harness = try canvas()
        let center = CGPoint(x: 200, y: 150), radius: CGFloat = 80
        let rough = StrokeFixtures.rough(StrokeFixtures.circlePositions(center: center, radius: radius), wobble: 8)
        harness.draw(StrokeFixtures.held(rough, for: 0.8))
        let layer = harness.pixels(of: harness.drawingLayer.texture)

        for alpha in onTheCircle(layer, center: center, radius: radius) {
            XCTAssertGreaterThan(alpha, 0.8, "ink all the way round the ideal circle")
        }
        XCTAssertEqual(layer.at(x: 200, y: 150).w, 0, "nothing in the middle")
        // Where the rough stroke strayed furthest from the circle there is now nothing
        let strays = rough.map(\.position).filter { abs(hypot($0.x - center.x, $0.y - center.y) - radius) > 6 }
        XCTAssertGreaterThan(strays.count, 10, "the rough circle did stray")
        for p in strays {
            XCTAssertEqual(layer.at(x: Int(p.x), y: Int(p.y)).w, 0, accuracy: 0.001, "no ink left where the hand wandered")
        }
        XCTAssertEqual(harness.viewModel.undoManager.undoCount, 1, "one stroke")
        XCTAssertNil(harness.viewModel.snappedShapeName, "cleared at pen-up")
    }

    func testTheShapeIsNamedWhileHeldAndTheStrokeSnapsBackWhenThePenMovesOn() throws {
        let harness = try canvas()
        let center = CGPoint(x: 200, y: 150), radius: CGFloat = 80
        let rough = StrokeFixtures.rough(StrokeFixtures.circlePositions(center: center, radius: radius), wobble: 8)
        let held = StrokeFixtures.held(rough, for: 0.8)

        harness.renderer.beginStroke()
        harness.viewModel.beginStroke(point: held[0])
        for point in held.dropFirst() { harness.viewModel.continueStroke(point: point) }
        XCTAssertEqual(harness.viewModel.snappedShapeName, "Circle")
        harness.renderFrame()

        // The composite shows the circle before pen-up
        let shown = harness.composite()
        XCTAssertGreaterThan(shown.at(x: Int(center.x + radius), y: Int(center.y)).w, 0.8)

        // Moving on: back to the stroke as drawn, continued
        let last = held.last!
        for i in 1...20 {
            harness.viewModel.continueStroke(point: StrokePoint(
                position: CGPoint(x: last.position.x + CGFloat(i) * 3, y: last.position.y),
                pressure: 0.7, tiltX: 0, tiltY: 0, rotation: 0, timestamp: last.timestamp + Double(i) * 0.01))
        }
        XCTAssertNil(harness.viewModel.snappedShapeName)
        harness.renderer.finalizeStroke()
        harness.viewModel.endStroke()
        let layer = harness.pixels(of: harness.drawingLayer.texture)
        let strays = rough.map(\.position).filter { abs(hypot($0.x - center.x, $0.y - center.y) - radius) > 6 }
        XCTAssertTrue(strays.contains { layer.at(x: Int($0.x), y: Int($0.y)).w > 0.5 }, "the hand-drawn stroke is back")
        XCTAssertGreaterThan(layer.at(x: Int(last.position.x + 45), y: Int(last.position.y)).w, 0.5, "with its continuation")
    }

    func testSnappingCanBeTurnedOffAndDoesNotApplyToSmudging() throws {
        let harness = try canvas()
        harness.viewModel.snapsShapesOnHold = false
        let center = CGPoint(x: 200, y: 150), radius: CGFloat = 80
        let rough = StrokeFixtures.rough(StrokeFixtures.circlePositions(center: center, radius: radius), wobble: 8)
        harness.draw(StrokeFixtures.held(rough, for: 0.8))
        let layer = harness.pixels(of: harness.drawingLayer.texture)
        let strays = rough.map(\.position).filter { abs(hypot($0.x - center.x, $0.y - center.y) - radius) > 6 }
        XCTAssertTrue(strays.contains { layer.at(x: Int($0.x), y: Int($0.y)).w > 0.5 }, "drawn as it was")

        let smudging = try canvas()
        smudging.fill(smudging.drawingLayer, red: 1, green: 0, blue: 0)
        smudging.select(.smudge)
        smudging.draw(StrokeFixtures.held(rough, for: 0.8))
        XCTAssertNil(smudging.viewModel.snappedShapeName)
    }

    /// Thick paint laid along the rough stroke is taken back when the stroke snaps.
    func testThickPaintFollowsTheSnap() throws {
        let harness = try EngineHarness(width: 400, height: 200)
        harness.select(.oil)
        harness.viewModel.brushSize = 20
        harness.viewModel.currentColor = ink
        let ideal = (0...100).map { CGPoint(x: 40 + CGFloat($0) * 3.2, y: 100) }
        let rough = StrokeFixtures.rough(ideal, wobble: 14)

        let held = StrokeFixtures.held(rough, for: 0.8)
        harness.renderer.beginStroke()
        harness.viewModel.beginStroke(point: held[0])
        for (index, point) in held.dropFirst().enumerated() {
            harness.viewModel.continueStroke(point: point)
            if index % 3 == 0 { harness.renderFrame() }
        }
        XCTAssertEqual(harness.viewModel.snappedShapeName, "Line")
        // Where the rough stroke strayed beyond the brush's reach from the snapped line
        let a = try XCTUnwrap(harness.viewModel.snappedPath?.samples.first?.position)
        let b = try XCTUnwrap(harness.viewModel.snappedPath?.samples.last?.position)
        func offLine(_ p: CGPoint) -> CGFloat {
            abs((p.x - a.x) * (b.y - a.y) - (p.y - a.y) * (b.x - a.x)) / hypot(b.x - a.x, b.y - a.y)
        }
        let strays = rough.map(\.position).filter { offLine($0) > 11 }
        XCTAssertGreaterThan(strays.count, 5, "the rough line strays beyond the brush's reach")
        harness.renderFrame()
        harness.renderer.finalizeStroke()
        harness.viewModel.endStroke()

        let heights = harness.heights(of: harness.drawingLayer)
        let middle = CGPoint(x: (a.x + b.x) / 2, y: (a.y + b.y) / 2)
        XCTAssertGreaterThan(heights.at(x: Int(middle.x), y: Int(middle.y)).x, 0.1, "thick along the line")
        for p in strays {
            XCTAssertEqual(heights.at(x: Int(p.x), y: Int(p.y)).x, 0, accuracy: 0.001, "none where the hand wandered")
        }
        harness.viewModel.performUndo(renderer: harness.renderer)
        XCTAssertEqual(harness.heights(of: harness.drawingLayer).at(x: Int(middle.x), y: Int(middle.y)).x, 0, accuracy: 0.001)
    }

    /// A brush that thins with speed draws the snapped shape at the pace the stroke was
    /// drawn, so a slow careful circle snaps to a circle as wide as the stroke.
    func testASnappedShapeIsDrawnAtTheStrokesOwnPace() throws {
        func ink(_ grid: PixelGrid) -> Float { stride(from: 3, to: grid.values.count, by: 4).reduce(0) { $0 + grid.values[$1] } }
        let center = CGPoint(x: 200, y: 150), radius: CGFloat = 80
        let positions = StrokeFixtures.circlePositions(center: center, radius: radius)

        let snapped = try EngineHarness(width: 400, height: 300)
        snapped.select(.inkBrush)
        snapped.viewModel.brushSize = 14
        snapped.draw(StrokeFixtures.held(StrokeFixtures.rough(positions, wobble: 8, duration: 4), for: 0.8))
        let drawn = try EngineHarness(width: 400, height: 300)
        drawn.select(.inkBrush)
        drawn.viewModel.brushSize = 14
        drawn.draw(StrokeFixtures.rough(positions, wobble: 0, duration: 4))

        let snappedInk = ink(snapped.pixels(of: snapped.drawingLayer.texture))
        let drawnInk = ink(drawn.pixels(of: drawn.drawingLayer.texture))
        XCTAssertGreaterThan(drawnInk, 1000)
        XCTAssertEqual(snappedInk, drawnInk, accuracy: drawnInk * 0.12, "as much ink as the circle drawn slowly")
    }

    /// An airbrush held still is spraying on purpose, not asking for a shape.
    func testAnAirbrushHeldStillSpraysRatherThanSnapping() throws {
        let harness = try canvas()
        harness.select(.airbrush)
        let rough = StrokeFixtures.rough(StrokeFixtures.circlePositions(center: CGPoint(x: 200, y: 150), radius: 80), wobble: 8)
        let held = StrokeFixtures.held(rough, for: 0.8)
        harness.renderer.beginStroke()
        harness.viewModel.beginStroke(point: held[0])
        for point in held.dropFirst() { harness.viewModel.continueStroke(point: point) }
        XCTAssertNil(harness.viewModel.snappedShapeName)
        harness.renderer.finalizeStroke()
        harness.viewModel.endStroke()
    }
}
