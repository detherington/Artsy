import XCTest
#if canImport(Artsy)
@testable import Artsy
#endif
@testable import ArtsyEngine

/// Perspective guides: one, two or three vanishing points, the lines a stroke can run
/// along, strokes held to them, the handles that move them, and their saving.
final class PerspectiveTests: XCTestCase {
    /// Two-point perspective on a 400 × 300 canvas: the horizon level at 260, one point up
    /// on the right of the canvas and one far off its left.
    private let twoPoint = PerspectiveGuide(points: [CGPoint(x: 380, y: 260), CGPoint(x: -300, y: 260)])

    /// The way from (60, 60) to the right-hand point.
    private var towardRight: CGVector {
        let length = (CGFloat(320) * 320 + CGFloat(200) * 200).squareRoot()
        return CGVector(dx: 320 / length, dy: 200 / length)
    }

    /// How far `point` is from the line through `a` along the unit vector `v`.
    private func distance(of point: CGPoint, fromLineThrough a: CGPoint, along v: CGVector) -> CGFloat {
        abs((point.x - a.x) * v.dy - (point.y - a.y) * v.dx)
    }

    // MARK: - The lines a stroke can run along

    func testEachKindOffersItsLines() {
        let start = CGPoint(x: 100, y: 100)
        let one = PerspectiveGuide(points: [CGPoint(x: 200, y: 150)])
        XCTAssertEqual(one.directions(from: start).map { $0.direction }, [.toward(0), .level, .upright])
        XCTAssertEqual(twoPoint.directions(from: start).map { $0.direction }, [.toward(0), .toward(1), .upright])
        let three = PerspectiveGuide(points: twoPoint.points + [CGPoint(x: 200, y: -900)])
        XCTAssertEqual(three.directions(from: start).map { $0.direction }, [.toward(0), .toward(1), .toward(2)])
        XCTAssertEqual(one.directions(from: CGPoint(x: 200, y: 150)).map { $0.direction }, [.level, .upright],
                       "none toward a point the line starts on")

        // A level horizon is level, its upright straight up, whichever way round the points are
        XCTAssertEqual(twoPoint.horizon.dx, 1, accuracy: 1e-9)
        XCTAssertEqual(twoPoint.horizon.dy, 0, accuracy: 1e-9)
        let upright = try! XCTUnwrap(twoPoint.directions(from: start).last?.vector)
        XCTAssertEqual(abs(upright.dy), 1, accuracy: 1e-9)
        // A tilted one tilts its upright with it
        let tilted = PerspectiveGuide(points: [CGPoint(x: 0, y: 0), CGPoint(x: 100, y: 100)])
        let tiltedUpright = try! XCTUnwrap(tilted.directions(from: start).last?.vector)
        XCTAssertEqual(tiltedUpright.dx * tilted.horizon.dx + tiltedUpright.dy * tilted.horizon.dy, 0, accuracy: 1e-9)
    }

    /// The pen's way picks the nearest line, going toward a point or away from it alike.
    func testThePensWayPicksTheNearestLineEitherWayAlongIt() {
        let start = CGPoint(x: 60, y: 60)
        // Toward the right-hand point is up and to the right, about 32°
        XCTAssertEqual(twoPoint.direction(from: start, moving: CGVector(dx: 10, dy: 7))?.direction, .toward(0))
        XCTAssertEqual(twoPoint.direction(from: start, moving: CGVector(dx: -10, dy: -7))?.direction, .toward(0), "and back from it")
        XCTAssertEqual(twoPoint.direction(from: start, moving: CGVector(dx: -10, dy: 5))?.direction, .toward(1))
        XCTAssertEqual(twoPoint.direction(from: start, moving: CGVector(dx: 1, dy: -10))?.direction, .upright)
        XCTAssertNil(twoPoint.direction(from: start, moving: .zero), "no way, no line")
    }

    // MARK: - A stroke held to the perspective

    /// A stroke stays where it began until the pen has gone ten screen points, then keeps
    /// to the line it chose, however the pen wanders, the far side of its start too.
    func testAStrokeWaitsToChooseThenKeepsToItsLine() {
        let start = CGPoint(x: 60, y: 60)
        var held = PerspectiveStroke(guide: twoPoint, anchor: start, zoom: 1)
        XCTAssertEqual(held.place(CGPoint(x: 64, y: 63)), start, "5 px: still at the start")
        XCTAssertNil(held.direction)
        _ = held.place(CGPoint(x: 69, y: 66))
        XCTAssertEqual(held.direction, .toward(0), "past 10 px it chooses")
        let toward = towardRight
        for wander in [CGPoint(x: 150, y: 140), CGPoint(x: 300, y: 150), CGPoint(x: 20, y: 30)] {
            let placed = held.place(wander)
            XCTAssertEqual(distance(of: placed, fromLineThrough: start, along: toward), 0, accuracy: 1e-9, "\(wander) onto the line")
        }
        XCTAssertEqual(held.direction, .toward(0), "chosen once")

        // Zoomed in, ten screen points is less of the canvas
        var close = PerspectiveStroke(guide: twoPoint, anchor: start, zoom: 4)
        _ = close.place(CGPoint(x: 63, y: 62))
        XCTAssertNotNil(close.direction, "3.6 px is 14 points at four times")
        // And a predicted touch is placed without choosing
        let fresh = PerspectiveStroke(guide: twoPoint, anchor: start, zoom: 1)
        XCTAssertEqual(fresh.preview(CGPoint(x: 200, y: 200)), start)
    }

    /// A wandering stroke toward a vanishing point draws exactly along the line to it; with
    /// the snap off, the wander shows. The guide's upright holds a leaning one to a vertical.
    func testStrokesInPerspectiveRunExactlyAlongTheirLines() throws {
        let start = CGPoint(x: 60, y: 60)
        let toward = towardRight
        let across = CGVector(dx: -toward.dy, dy: toward.dx)
        /// 240 px along the line to the right-hand point, wandering up to 4 px across it
        let wandering = StrokeFixtures.sampled(duration: 1) { t -> (CGPoint, Float) in
            let along = 240 * CGFloat(t)
            let wave = sin(3 * Double.pi * t)
            let off = CGFloat(4 * wave * wave)
            let x: CGFloat = start.x + toward.dx * along + across.dx * off
            let y: CGFloat = start.y + toward.dy * along + across.dy * off
            return (CGPoint(x: x, y: y), 0.8)
        }
        func ink(_ stroke: [StrokePoint], snapping: Bool) throws -> PixelGrid {
            let harness = try EngineHarness(width: 400, height: 300)
            harness.select(.hardRound)
            harness.viewModel.brushSize = 6
            var perspective = twoPoint
            perspective.snaps = snapping
            harness.viewModel.guides.perspective = perspective
            harness.draw(stroke)
            XCTAssertNil(harness.viewModel.perspectiveStroke, "let go at pen-up")
            return harness.pixels(of: harness.drawingLayer.texture)
        }
        func at(_ along: CGFloat, _ off: CGFloat, in grid: PixelGrid) -> Float {
            grid.at(x: Int((start.x + toward.dx * along + across.dx * off).rounded()),
                    y: Int((start.y + toward.dy * along + across.dy * off).rounded())).w
        }
        let held = try ink(wandering, snapping: true)
        // The wander's peaks are a sixth, a half and five sixths along
        for along: CGFloat in [40, 120, 200] {
            XCTAssertGreaterThan(at(along, 0, in: held), 0.9, "ink on the line \(along) px along")
            XCTAssertEqual(at(along, 5.5, in: held), 0, accuracy: 0.001, "none off it")
        }
        let free = try ink(wandering, snapping: false)
        XCTAssertTrue([40, 120, 200].contains { at($0, 5.5, in: free) > 0.5 }, "without the snap the wander shows")

        // Up the page, leaning 12 px to the right over 200: upright, so straight up
        let leaning = StrokeFixtures.sampled(duration: 1) { t -> (CGPoint, Float) in
            (CGPoint(x: 200 + 12 * CGFloat(t), y: 40 + 200 * CGFloat(t)), 0.8)
        }
        let upright = try ink(leaning, snapping: true)
        XCTAssertGreaterThan(upright.at(x: 200, y: 230).w, 0.9)
        XCTAssertEqual(upright.at(x: 209, y: 230).w, 0, accuracy: 0.001, "not where the pen leant")
    }

    /// The touches iOS predicts are placed on the stroke's line too, or at its start before
    /// it has one; a stroke without the snap, or with the guide hidden, is not held at all.
    func testPredictedTouchesFollowAndOnlyAShownSnappingGuideHolds() throws {
        let harness = try EngineHarness(width: 400, height: 300)
        let viewModel = harness.viewModel
        viewModel.guides.perspective = twoPoint
        let start = CGPoint(x: 60, y: 60)
        func sample(_ p: CGPoint, _ t: TimeInterval) -> StrokePoint {
            StrokePoint(position: p, pressure: 0.8, tiltX: 0, tiltY: 0, rotation: 0, timestamp: t)
        }
        harness.renderer.beginStroke()
        viewModel.beginStroke(point: sample(start, 0), input: .pen)
        XCTAssertNotNil(viewModel.perspectiveStroke)
        viewModel.predictStroke([sample(CGPoint(x: 90, y: 90), 0.01)])
        XCTAssertEqual(viewModel.predictedSamples.first?.position, start, "no line yet: at the start")
        viewModel.continueStroke(point: sample(CGPoint(x: 80, y: 72), 0.02))
        viewModel.predictStroke([sample(CGPoint(x: 120, y: 120), 0.03)])
        let toward = towardRight
        let predicted = try XCTUnwrap(viewModel.predictedSamples.first?.position)
        XCTAssertEqual(distance(of: predicted, fromLineThrough: start, along: toward), 0, accuracy: 1e-6)
        harness.renderer.finalizeStroke()
        viewModel.endStroke()

        for change in [{ (p: inout PerspectiveGuide) in p.snaps = false }, { (p: inout PerspectiveGuide) in p.isShown = false }] {
            var perspective = twoPoint
            change(&perspective)
            viewModel.guides.perspective = perspective
            harness.renderer.beginStroke()
            viewModel.beginStroke(point: sample(start, 0), input: .pen)
            XCTAssertNil(viewModel.perspectiveStroke)
            harness.renderer.finalizeStroke()
            viewModel.endStroke()
        }
    }

    /// A stroke that starts by a guide line starts on it, and is held to the perspective
    /// from there.
    func testAStrokeStartingByAGuideStartsOnIt() throws {
        let harness = try EngineHarness(width: 400, height: 300)
        let viewModel = harness.viewModel
        viewModel.guides.verticals = [100]
        viewModel.guides.perspective = twoPoint
        harness.renderer.beginStroke()
        viewModel.beginStroke(point: StrokePoint(position: CGPoint(x: 104, y: 50), pressure: 0.8, tiltX: 0, tiltY: 0,
                                                 rotation: 0, timestamp: 0), input: .pen)
        XCTAssertEqual(viewModel.perspectiveStroke?.anchor, CGPoint(x: 100, y: 50))
        harness.renderer.finalizeStroke()
        viewModel.endStroke()
    }

    // MARK: - Drawing the guide

    /// A point off the canvas sends its rays across the canvas, every one on it; a point on
    /// it sends them all round. The horizon runs across.
    func testTheRaysCrossTheCanvasFromWhereverThePointIs() {
        let canvas = CGRect(x: 0, y: 0, width: 400, height: 300)
        let far = twoPoint.rays(from: 1, across: canvas, count: 18)
        XCTAssertEqual(far.count, 18, "all of them cross the canvas")
        for (a, b) in far {
            XCTAssertTrue(canvas.insetBy(dx: -0.01, dy: -0.01).contains(a) && canvas.insetBy(dx: -0.01, dy: -0.01).contains(b))
            // Each runs on the line from the point
            let v = CGVector(dx: b.x - a.x, dy: b.y - a.y)
            let length = hypot(v.dx, v.dy)
            XCTAssertEqual(distance(of: twoPoint.points[1], fromLineThrough: a, along: CGVector(dx: v.dx / length, dy: v.dy / length)), 0, accuracy: 1e-6)
        }
        // Spread across the canvas: the first and last reach its corners' sides
        let ends = far.map { $0.1.y }
        XCTAssertLessThan(ends.min()!, 40)
        XCTAssertGreaterThan(ends.max()!, 260)

        let near = twoPoint.rays(from: 0, across: canvas, count: 18)
        XCTAssertEqual(near.count, 36, "all round a point on the canvas")
        XCTAssertTrue(near.allSatisfy { $0.0 == twoPoint.points[0] })

        let horizon = twoPoint.horizonLine(across: canvas)
        XCTAssertEqual(horizon?.0.y ?? 0, 260, accuracy: 1e-9)
        XCTAssertEqual(abs((horizon?.1.x ?? 0) - (horizon?.0.x ?? 0)), 400, accuracy: 1e-6, "the whole way across")
        let above = PerspectiveGuide(points: [CGPoint(x: 100, y: 500)])
        XCTAssertNil(above.horizonLine(across: canvas), "a horizon above the canvas misses it")
    }

    // MARK: - Moving the points

    func testHandlesMoveThePointsAndTheHorizon() {
        var guide = twoPoint
        XCTAssertEqual(guide.handle(near: CGPoint(x: 385, y: 255), reach: 24), .point(0))
        XCTAssertEqual(guide.horizonHandle, CGPoint(x: 40, y: 260))
        XCTAssertEqual(guide.handle(near: CGPoint(x: 45, y: 262), reach: 24), .horizon)
        XCTAssertNil(guide.handle(near: CGPoint(x: 200, y: 100), reach: 24))
        guide.move(.horizon, by: CGVector(dx: 0, dy: -60))
        XCTAssertEqual(guide.points, [CGPoint(x: 380, y: 200), CGPoint(x: -300, y: 200)], "the horizon moves both")
        guide.move(.point(1), by: CGVector(dx: 0, dy: 30))
        XCTAssertEqual(guide.points[1], CGPoint(x: -300, y: 230))
        guide.levelHorizon()
        XCTAssertEqual(guide.points[1].y, 200, "levelled to the first")

        // One point keeps the horizon's middle; two again go across the screen on it; a
        // third goes below, and stays where it was moved to when two keep their places
        let left = CGPoint(x: 40, y: 150), right = CGPoint(x: 360, y: 150), below = CGPoint(x: 200, y: 24)
        let one = guide.with(points: 1, left: left, right: right, below: below)
        XCTAssertEqual(one.points, [CGPoint(x: 40, y: 200)])
        let two = one.with(points: 2, left: left, right: right, below: below)
        XCTAssertEqual(two.points, [CGPoint(x: 40, y: 200), CGPoint(x: 360, y: 200)], "on the horizon, across the screen")
        var three = two.with(points: 3, left: left, right: right, below: below)
        XCTAssertEqual(three.points.last, below)
        three.points[2] = CGPoint(x: 220, y: -500)
        XCTAssertEqual(three.with(points: 3, left: left, right: right, below: below).points[2], CGPoint(x: 220, y: -500))
        XCTAssertEqual(three.with(points: 2, left: left, right: right, below: below).points, three.points.prefix(2).map { $0 })
    }

    /// Edited through the view model, as the canvases do: two points laid out across the
    /// screen, a point picked up and dragged, the horizon dragged, presses elsewhere picking
    /// up nothing; the document marked changed; removing it.
    func testEditingThroughTheViewModel() throws {
        let viewModel = CanvasViewModel(canvasSize: CGSize(width: 400, height: 300))
        let view = CGSize(width: 400, height: 300)
        // The canvas fills the view one to one
        viewModel.transform.scale = 1
        viewModel.transform.offset = CGPoint(x: -200, y: -150)
        viewModel.editPerspective(viewSize: view)
        XCTAssertTrue(viewModel.isEditingPerspective)
        let laidOut = try XCTUnwrap(viewModel.guides.perspective)
        XCTAssertEqual(laidOut.points.count, 2)
        XCTAssertEqual(laidOut.points[0].x, 40, accuracy: 1)
        XCTAssertEqual(laidOut.points[1].x, 360, accuracy: 1)
        XCTAssertEqual(laidOut.points[0].y, 150, accuracy: 1)
        XCTAssertEqual(laidOut.points[1].y, laidOut.points[0].y, accuracy: 1e-9, "level")

        viewModel.markClean()
        XCTAssertTrue(viewModel.perspectiveDown(at: CGPoint(x: 42, y: 148)))
        viewModel.perspectiveDrag(to: CGPoint(x: 52, y: 168))
        viewModel.perspectiveUp()
        XCTAssertEqual(viewModel.guides.perspective!.points[0].x, laidOut.points[0].x + 10, accuracy: 1e-9)
        XCTAssertEqual(viewModel.guides.perspective!.points[0].y, laidOut.points[0].y + 20, accuracy: 1e-9)
        XCTAssertTrue(viewModel.isDirty)

        let middle = try XCTUnwrap(viewModel.guides.perspective?.horizonHandle)
        XCTAssertTrue(viewModel.perspectiveDown(at: middle))
        viewModel.perspectiveDrag(to: CGPoint(x: middle.x, y: middle.y - 50))
        viewModel.perspectiveUp()
        XCTAssertEqual(viewModel.guides.perspective!.points[1].y, laidOut.points[1].y - 50, accuracy: 1e-9)
        XCTAssertFalse(viewModel.perspectiveDown(at: CGPoint(x: 200, y: 280)), "nothing there")

        // Zoomed out, the reach is the same on the screen and more of the canvas
        viewModel.transform.scale = 0.25
        let point = viewModel.guides.perspective!.points[1]
        XCTAssertNotNil(viewModel.perspectiveHandle(near: CGPoint(x: point.x + 80, y: point.y)))

        viewModel.setPerspective(points: 3, viewSize: view)
        XCTAssertEqual(viewModel.guides.perspective?.points.count, 3)
        viewModel.endPerspectiveEditing()
        XCTAssertFalse(viewModel.isEditingPerspective)
        viewModel.changeGuides { $0.perspective?.isShown = false }
        XCTAssertNil(viewModel.perspectiveHandle(near: point), "a hidden guide has no handles")
        viewModel.editPerspective(viewSize: view)
        XCTAssertEqual(viewModel.guides.perspective?.isShown, true, "editing shows it again")
        XCTAssertEqual(viewModel.guides.perspective?.points.count, 3, "as it was")
        viewModel.removePerspective()
        XCTAssertNil(viewModel.guides.perspective)
        XCTAssertFalse(viewModel.isEditingPerspective)
    }

    // MARK: - Saving

    func testSavedWithTheGuidesAndAbsentFromOlderDocuments() throws {
        var guides = CanvasGuides(verticals: [100])
        var perspective = twoPoint
        perspective.snaps = false
        guides.perspective = perspective
        let data = try JSONEncoder().encode(guides)
        XCTAssertEqual(try JSONDecoder().decode(CanvasGuides.self, from: data), guides)
        let older = try JSONEncoder().encode(CanvasGuides(verticals: [100]))
        XCTAssertFalse(String(decoding: older, as: UTF8.self).contains("perspective"), "none, none written")
        XCTAssertNil(try JSONDecoder().decode(CanvasGuides.self, from: older).perspective)
    }
}
