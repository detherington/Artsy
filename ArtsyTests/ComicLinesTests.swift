import XCTest
#if canImport(Artsy)
@testable import Artsy
#endif
@testable import ArtsyEngine

/// Speed lines and focus lines: their shapes round the clear area, their settings' steps,
/// making them into a layer in the current colour as one step, a selection keeping them
/// inside it, and laying them out through the view model.
final class ComicLinesTests: XCTestCase {
    private let canvas = CGSize(width: 400, height: 300)
    /// The subject: an ellipse in the middle of the canvas, 120 × 80, turned a little.
    private let clear = EllipseGuide(centre: CGPoint(x: 200, y: 150), radii: CGSize(width: 60, height: 40), rotation: 0.3)

    private func cross(_ a: CGPoint, _ b: CGPoint, _ c: CGPoint) -> CGFloat {
        (b.x - a.x) * (c.y - a.y) - (b.y - a.y) * (c.x - a.x)
    }

    // MARK: - Their shapes

    /// Each focus line is a wedge from beyond the canvas's edge to a point on the clear
    /// area's edge, or pulled back from it by up to 60% of the run with full variety (30% at
    /// a half), aimed at its centre.
    func testFocusLinesRunInFromTheEdgesToTheClearArea() {
        var focus = ComicLines(kind: .focus, clear: clear, count: 60, width: 6, variety: 0.5, seed: 7)
        let lines = focus.lines(canvasSize: canvas)
        XCTAssertEqual(lines.count, 60, "every line, the centre being on the canvas")
        let bounds = CGRect(origin: .zero, size: canvas).insetBy(dx: -0.5, dy: -0.5)
        for line in lines {
            XCTAssertFalse(line.isSpindle)
            XCTAssertFalse(bounds.contains(line.start), "its wide end beyond the edge")
            let tip = clear.scale(through: line.end)
            XCTAssertGreaterThanOrEqual(tip, 1 - 1e-6, "its point at or past the clear area's edge")
            let toTip = hypot(line.end.x - clear.centre.x, line.end.y - clear.centre.y)
            let edge = toTip / tip
            let exit = ComicLines.exit(from: clear.centre, along: CGVector(dx: (line.end.x - clear.centre.x) / toTip,
                                                                          dy: (line.end.y - clear.centre.y) / toTip),
                                       of: CGRect(origin: .zero, size: canvas))!
            XCTAssertLessThanOrEqual(toTip, edge + 0.3 * (exit - edge) + 1e-6, "pulled back no more than 30% of the run")
            XCTAssertEqual(cross(clear.centre, line.start, line.end) / hypot(line.start.x - line.end.x, line.start.y - line.end.y),
                           0, accuracy: 1e-6, "aimed at the centre")
            XCTAssertLessThanOrEqual(line.width, 6)
            XCTAssertGreaterThanOrEqual(line.width, 6 * 0.65 - 1e-9)
        }
        // With no variety, every point is on the edge and every line as wide
        focus.variety = 0
        for line in focus.lines(canvasSize: canvas) {
            XCTAssertEqual(clear.scale(through: line.end), 1, accuracy: 1e-6)
            XCTAssertEqual(line.width, 6)
        }
        // The same seed deals the same lines; shuffling deals others
        focus.variety = 0.5
        XCTAssertEqual(focus.lines(canvasSize: canvas), lines)
        focus.shuffle()
        XCTAssertNotEqual(focus.lines(canvasSize: canvas), lines)
    }

    /// Speed lines are spindles along the clear area's long axis, spread across the whole
    /// canvas; keeping it clear, none crosses it; running through it, some do.
    func testSpeedLinesRunAlongTheClearAreaAndKeepItClear() {
        var speed = ComicLines(kind: .speed, clear: clear, count: 80, width: 4, variety: 0.6, seed: 3)
        let lines = speed.lines(canvasSize: canvas)
        XCTAssertGreaterThanOrEqual(lines.count, 60)
        let v = CGVector(dx: cos(0.3), dy: sin(0.3))
        var offsets: [CGFloat] = []
        func crossesClear(_ line: ComicLines.Line) -> Bool {
            (0...40).contains { i in
                let t = CGFloat(i) / 40
                return clear.scale(through: CGPoint(x: line.start.x + (line.end.x - line.start.x) * t,
                                                    y: line.start.y + (line.end.y - line.start.y) * t)) < 1 - 1e-6
            }
        }
        for line in lines {
            XCTAssertTrue(line.isSpindle)
            let length = hypot(line.end.x - line.start.x, line.end.y - line.start.y)
            XCTAssertEqual(((line.end.x - line.start.x) * v.dy - (line.end.y - line.start.y) * v.dx) / length, 0, accuracy: 1e-9,
                           "along the clear area's axis")
            XCTAssertGreaterThanOrEqual(length, 3 * line.width, "no stubs")
            XCTAssertFalse(crossesClear(line), "the subject kept clear")
            offsets.append((line.start.x - 200) * -v.dy + (line.start.y - 150) * v.dx)
        }
        // Across the canvas square to them, from one corner's reach to the other's
        let reach = 200 * sin(0.3) + 150 * cos(0.3)
        XCTAssertLessThan(offsets.min()!, -0.85 * reach)
        XCTAssertGreaterThan(offsets.max()!, 0.85 * reach)

        speed.keepsClear = false
        XCTAssertTrue(speed.lines(canvasSize: canvas).contains(where: crossesClear), "through the subject when asked")
    }

    func testTheSettingsStepWithinTheirRanges() {
        var lines = ComicLines(kind: .focus, clear: clear, count: 120, width: 8, variety: 0.5)
        lines.stepCount(by: 1)
        XCTAssertEqual(lines.count, 140)
        lines.stepCount(by: 50)
        XCTAssertEqual(lines.count, 400)
        lines.stepCount(by: -50)
        XCTAssertEqual(lines.count, 20)
        lines.stepWidth(by: 1)
        XCTAssertEqual(lines.width, 10, accuracy: 1e-9)
        lines.stepWidth(by: -30)
        XCTAssertEqual(lines.width, 1, "never under a pixel")
        lines.stepVariety(by: 1)
        XCTAssertEqual(lines.variety, 0.6, accuracy: 1e-9)
        lines.stepVariety(by: 9)
        XCTAssertEqual(lines.variety, 1)
        lines.stepVariety(by: -20)
        XCTAssertEqual(lines.variety, 0)
        let made = ComicLines.laidOut(kind: .speed, clear: clear, canvasSize: CGSize(width: 2048, height: 2752))
        XCTAssertEqual(made.count, 80)
        XCTAssertEqual(made.width, 11, "half a percent of the short side, rounded up")
    }

    // MARK: - Making them

    /// Made into a new layer named for them, above the current one and current, in the
    /// current colour, none in the clear area: one step, which undo takes back.
    func testMakingThemAddsALayerInTheColourAsOneStep() throws {
        let harness = try EngineHarness(width: 400, height: 300)
        let viewModel = harness.viewModel
        viewModel.currentColor = StrokeColor(red: 1, green: 0, blue: 0, alpha: 1)
        viewModel.comicLines = ComicLines(kind: .focus, clear: clear, count: 90, width: 10, variety: 0.3)
        viewModel.editingGuide = .lines
        let before = harness.layerStack.layers.count
        let active = harness.layerStack.activeLayerIndex
        try viewModel.makeLines(renderer: harness.renderer)
        XCTAssertEqual(harness.layerStack.layers.count, before + 1)
        XCTAssertEqual(harness.layerStack.activeLayerIndex, active + 1)
        let layer = harness.layerStack.layers[active + 1]
        XCTAssertEqual(layer.name, "Focus lines")
        XCTAssertNil(viewModel.comicLines, "laid out no longer")
        XCTAssertNil(viewModel.editingGuide)

        let grid = harness.pixels(of: layer.texture)
        XCTAssertEqual(grid.at(x: 200, y: 150).w, 0, accuracy: 0.001, "the clear area clear")
        XCTAssertEqual(grid.at(x: 230, y: 160).w, 0, accuracy: 0.001)
        // Round the edge of the canvas, where the lines are widest, there is ink, in red
        var inked: [SIMD4<Float>] = []
        for x in stride(from: 2, to: 398, by: 3) { inked += [grid.at(x: x, y: 2), grid.at(x: x, y: 297)].filter { $0.w > 0.95 } }
        XCTAssertGreaterThan(inked.count, 20, "lines along the top and bottom edges")
        for pixel in inked.prefix(10) {
            XCTAssertGreaterThan(pixel.x, 0.9)
            XCTAssertLessThan(pixel.y, 0.1)
        }

        viewModel.performUndo(renderer: harness.renderer)
        XCTAssertEqual(harness.layerStack.layers.count, before, "one step takes it back")
    }

    /// With a selection, the lines stay inside it: a corner of the canvas, y up, gets them
    /// and the rest none.
    func testASelectionKeepsThemInsideIt() throws {
        let harness = try EngineHarness(width: 400, height: 300)
        let viewModel = harness.viewModel
        var speed = ComicLines(kind: .speed, clear: clear, count: 120, width: 6, variety: 0.2)
        speed.keepsClear = false
        viewModel.comicLines = speed
        viewModel.editingGuide = .lines
        viewModel.selectionPath = CGPath(rect: CGRect(x: 0, y: 0, width: 200, height: 150), transform: nil)
        try viewModel.makeLines(renderer: harness.renderer)
        let grid = harness.pixels(of: harness.layerStack.layers[harness.layerStack.activeLayerIndex].texture)
        var inside = 0, outside = 0
        for y in stride(from: 1, to: 300, by: 2) {
            for x in stride(from: 1, to: 400, by: 2) where grid.at(x: x, y: y).w > 0.5 {
                if x < 200 && y < 150 { inside += 1 } else { outside += 1 }
            }
        }
        XCTAssertGreaterThan(inside, 200, "lines in the selected corner")
        XCTAssertEqual(outside, 0, "and nowhere else")
    }

    // MARK: - Laying them out

    func testLayingThemOutThroughTheViewModel() {
        let viewModel = CanvasViewModel(canvasSize: CGSize(width: 400, height: 300))
        let view = CGSize(width: 400, height: 300)
        viewModel.transform.scale = 1
        viewModel.transform.offset = CGPoint(x: -200, y: -150)
        viewModel.guides.ruler = RulerGuide(start: CGPoint(x: 100, y: 100), end: CGPoint(x: 300, y: 100))

        viewModel.startLines(.focus, viewSize: view)
        XCTAssertEqual(viewModel.editingGuide, .lines)
        let laidOut = viewModel.comicLines
        XCTAssertEqual(laidOut?.kind, .focus)
        XCTAssertEqual(laidOut?.clear.centre.x ?? 0, 200, accuracy: 1)
        XCTAssertEqual(laidOut?.clear.centre.y ?? 0, 150, accuracy: 1)
        XCTAssertEqual(laidOut?.clear.radii.width ?? 0, 40, accuracy: 1, "a fifth of the screen across")
        XCTAssertEqual(laidOut?.clear.degree ?? 0, 60, accuracy: 1e-6)
        XCTAssertEqual(laidOut?.count, 120)

        // The clear area's handles move it; the guides' are out of reach; nothing is saved
        viewModel.markClean()
        XCTAssertNil(viewModel.guideHandle(near: CGPoint(x: 100, y: 100)), "not the ruler's while laying out lines")
        XCTAssertTrue(viewModel.guideHandleDown(at: CGPoint(x: 202, y: 151)))
        viewModel.guideHandleDrag(to: CGPoint(x: 212, y: 131))
        viewModel.guideHandleUp()
        XCTAssertEqual(viewModel.comicLines?.clear.centre.x ?? 0, 210, accuracy: 1)
        XCTAssertEqual(viewModel.comicLines?.clear.centre.y ?? 0, 130, accuracy: 1)
        XCTAssertFalse(viewModel.isDirty, "lines laid out are not in the document")

        // Changing kind keeps the clear area, the variety and the lines' seed
        viewModel.comicLines?.variety = 0.8
        let seed = viewModel.comicLines?.seed
        viewModel.startLines(.speed, viewSize: view)
        XCTAssertEqual(viewModel.comicLines?.kind, .speed)
        XCTAssertEqual(viewModel.comicLines?.count, 80)
        XCTAssertEqual(viewModel.comicLines?.variety, 0.8)
        XCTAssertEqual(viewModel.comicLines?.seed, seed)
        XCTAssertEqual(viewModel.comicLines?.clear.centre.x ?? 0, 210, accuracy: 1)

        viewModel.endGuideEditing()
        XCTAssertNil(viewModel.comicLines, "ending lets them go, unmade")
        viewModel.startLines(.speed, viewSize: view)
        viewModel.cancelLines()
        XCTAssertNil(viewModel.comicLines)
        XCTAssertNil(viewModel.editingGuide)
    }
}
