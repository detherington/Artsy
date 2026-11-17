import XCTest
#if canImport(Artsy)
@testable import Artsy
#endif
@testable import ArtsyEngine

/// The ruler and the ellipse template: where a point goes on each, their handles and
/// degree, strokes laid against them held to them, which guide takes a stroke, editing them
/// through the view model, and their saving.
final class RulerAndEllipseTests: XCTestCase {
    /// A ruler slanting up across a 400 × 300 canvas.
    private let ruler = RulerGuide(start: CGPoint(x: 40, y: 60), end: CGPoint(x: 360, y: 240))
    /// An ellipse in the middle of a 400 × 300 canvas, 240 × 120, turned a little.
    private let ellipse = EllipseGuide(centre: CGPoint(x: 200, y: 150), radii: CGSize(width: 120, height: 60), rotation: 0.3)

    private func sample(_ p: CGPoint, _ t: TimeInterval) -> StrokePoint {
        StrokePoint(position: p, pressure: 0.8, tiltX: 0, tiltY: 0, rotation: 0, timestamp: t)
    }

    // MARK: - The ruler

    func testTheRulerProjectsMeasuresAndStraightens() {
        let d = ruler.direction
        XCTAssertEqual(hypot(d.dx, d.dy), 1, accuracy: 1e-9)
        XCTAssertEqual(ruler.angle, atan2(180, 320) * 180 / .pi, accuracy: 1e-9)
        XCTAssertEqual(RulerGuide(start: ruler.end, end: ruler.start).angle, ruler.angle, accuracy: 1e-9,
                       "a line has no way round")
        XCTAssertEqual(RulerGuide(start: CGPoint(x: 5, y: 9), end: CGPoint(x: 5, y: 2)).angle, 90, accuracy: 1e-9)
        XCTAssertEqual(RulerGuide(start: CGPoint(x: 9, y: 5), end: CGPoint(x: 2, y: 5)).angle, 0, accuracy: 1e-9)

        // Square onto its line, past its ends too
        let off = CGPoint(x: 200 - 30 * d.dy, y: 150 + 30 * d.dx)
        let onto = ruler.projected(off)
        XCTAssertEqual(onto.x, 200, accuracy: 1e-9)
        XCTAssertEqual(onto.y, 150, accuracy: 1e-9)
        XCTAssertEqual(ruler.distance(to: off), 30, accuracy: 1e-9)
        let past = CGPoint(x: 360 + 50 * d.dx, y: 240 + 50 * d.dy)
        XCTAssertEqual(ruler.projected(past).x, past.x, accuracy: 1e-9, "on its line past its end")
        XCTAssertEqual(ruler.distance(to: past), 50, accuracy: 1e-9, "but 50 px from the ruler itself")

        var straight = ruler
        straight.straighten()
        XCTAssertEqual(straight.angle, 30, accuracy: 1e-9, "29.4° to the nearest 15°")
        XCTAssertEqual(straight.length, ruler.length, accuracy: 1e-9)
        XCTAssertEqual(straight.middle.x, ruler.middle.x, accuracy: 1e-9)
        XCTAssertEqual(straight.middle.y, ruler.middle.y, accuracy: 1e-9)
    }

    func testTheRulersHandlesMoveAnEndOrTheWholeRuler() {
        var moved = ruler
        XCTAssertEqual(moved.handle(near: CGPoint(x: 44, y: 63), reach: 10), .start)
        XCTAssertEqual(moved.handle(near: CGPoint(x: 202, y: 148), reach: 10), .middle)
        XCTAssertNil(moved.handle(near: CGPoint(x: 120, y: 200), reach: 10))
        moved.move(.end, by: CGVector(dx: -10, dy: 20))
        XCTAssertEqual(moved.start, ruler.start)
        XCTAssertEqual(moved.end, CGPoint(x: 350, y: 260))
        moved.move(.middle, by: CGVector(dx: 5, dy: -5))
        XCTAssertEqual(moved.start, CGPoint(x: 45, y: 55))
        XCTAssertEqual(moved.end, CGPoint(x: 355, y: 255))
    }

    // MARK: - The ellipse

    /// The nearest point found is on the ellipse and no farther than the nearest of 20,000
    /// points round it, for long, tall and round ellipses, from inside and outside.
    func testTheNearestPointOnAnEllipseIsOnItAndNearest() {
        for (a, b) in [(CGFloat(120), CGFloat(60)), (40, 160), (80, 80), (300, 12)] {
            let around = (0..<20_000).map { i -> CGPoint in
                let t = CGFloat(i) / 20_000 * 2 * .pi
                return CGPoint(x: a * cos(t), y: b * sin(t))
            }
            for p in [CGPoint(x: 10, y: 5), CGPoint(x: -200, y: 90), CGPoint(x: 3, y: -150), CGPoint(x: a * 0.7, y: -b * 0.69),
                      CGPoint(x: -a - 5, y: 0.5), CGPoint(x: 0.2, y: b + 30)] {
                let n = EllipseGuide.nearestOnEllipse(a: a, b: b, to: p)
                XCTAssertEqual((n.x / a) * (n.x / a) + (n.y / b) * (n.y / b), 1, accuracy: 1e-6, "on it: \(a)×\(b) from \(p)")
                let found = hypot(p.x - n.x, p.y - n.y)
                let best = around.map { hypot(p.x - $0.x, p.y - $0.y) }.min()!
                XCTAssertLessThanOrEqual(found, best + 0.02, "nearest: \(a)×\(b) from \(p)")
            }
        }
    }

    func testTheEllipsesFrameScaleAndDistance() {
        let p = CGPoint(x: 250, y: 130)
        let back = ellipse.world(ellipse.local(p))
        XCTAssertEqual(back.x, p.x, accuracy: 1e-9)
        XCTAssertEqual(back.y, p.y, accuracy: 1e-9)
        // Half way out along its first axis is the half-size ellipse
        let half = ellipse.world(CGPoint(x: 60, y: 0))
        XCTAssertEqual(ellipse.scale(through: half), 0.5, accuracy: 1e-9)
        // Nearest is not the axis's end, 60 away, but (80, ±42.4), √2400 away
        XCTAssertEqual(ellipse.distance(to: half), 2400.0.squareRoot(), accuracy: 1e-6)
        let onHalf = ellipse.nearest(to: ellipse.world(CGPoint(x: 0, y: 40)), scale: 0.5)
        XCTAssertEqual(ellipse.local(onHalf).y, 30, accuracy: 1e-6)
        // Its placement draws the same ellipse: the rectangle's right edge is its first axis's end
        let end = CGPoint(x: 120, y: 0).applying(ellipse.placement)
        XCTAssertEqual(end.x, ellipse.position(of: .axis).x, accuracy: 1e-9)
        XCTAssertEqual(end.y, ellipse.position(of: .axis).y, accuracy: 1e-9)
    }

    /// Its degree, as a template marks it, steps by 5° keeping the long axis; its handles
    /// move it, turn it and set its radii; straightening turns it to the nearest 15°.
    func testTheEllipsesDegreeHandlesAndStraightening() {
        var e = EllipseGuide(centre: CGPoint(x: 100, y: 100), axisEnd: CGPoint(x: 100, y: 180), degree: 30)
        XCTAssertEqual(e.rotation, .pi / 2, accuracy: 1e-9, "its first axis upright")
        XCTAssertEqual(e.radii.width, 80, accuracy: 1e-9)
        XCTAssertEqual(e.radii.height, 40, accuracy: 1e-9)
        XCTAssertEqual(e.degree, 30, accuracy: 1e-9)
        e.stepDegree(by: 1)
        XCTAssertEqual(e.degree, 35, accuracy: 1e-9)
        XCTAssertEqual(e.radii.width, 80, accuracy: 1e-9, "the long axis kept")
        e.setDegree(90)
        XCTAssertEqual(e.radii.height, 80, accuracy: 1e-9, "a circle")
        e.setDegree(0)
        XCTAssertEqual(e.degree, 5, accuracy: 1e-9, "never flat")
        // Across longer than along: the long one is kept, the other set
        var tall = EllipseGuide(centre: .zero, radii: CGSize(width: 20, height: 100))
        tall.setDegree(30)
        XCTAssertEqual(tall.radii.height, 100, accuracy: 1e-9)
        XCTAssertEqual(tall.radii.width, 50, accuracy: 1e-9)

        var moved = ellipse
        XCTAssertEqual(moved.handle(near: ellipse.position(of: .across), reach: 10), .across)
        moved.move(.centre, by: CGVector(dx: 10, dy: -10))
        XCTAssertEqual(moved.centre, CGPoint(x: 210, y: 140))
        // The first axis's end taken straight up from the centre: turned upright, 50 long
        let axis = moved.position(of: .axis)
        moved.move(.axis, by: CGVector(dx: 210 - axis.x, dy: 190 - axis.y))
        XCTAssertEqual(moved.rotation, .pi / 2, accuracy: 1e-9)
        XCTAssertEqual(moved.radii.width, 50, accuracy: 1e-9)
        XCTAssertEqual(moved.radii.height, 60, accuracy: 1e-9, "the other radius kept")
        // The second axis's end dragged out along it and a little aside: only its radius changes
        let across = moved.position(of: .across)   // to the left of the upright axis
        moved.move(.across, by: CGVector(dx: -15, dy: 7))
        XCTAssertEqual(moved.radii.height, 75, accuracy: 1e-9)
        XCTAssertEqual(moved.position(of: .across).y, across.y, accuracy: 1e-9)
        XCTAssertEqual(moved.rotation, .pi / 2, accuracy: 1e-9)

        var turned = ellipse
        turned.straighten()
        XCTAssertEqual(turned.rotation, .pi / 12, accuracy: 1e-9, "0.3 rad (17°) to 15°")
    }

    // MARK: - Strokes held to them

    /// How much ink `grid` has at canvas point `p`.
    private func ink(at p: CGPoint, in grid: PixelGrid) -> Float {
        grid.at(x: Int(p.x.rounded()), y: Int(p.y.rounded())).w
    }

    private func drawn(_ stroke: [StrokePoint], guides: (inout CanvasGuides) -> Void) throws -> PixelGrid {
        let harness = try EngineHarness(width: 400, height: 300)
        harness.select(.hardRound)
        harness.viewModel.brushSize = 6
        guides(&harness.viewModel.guides)
        harness.draw(stroke)
        XCTAssertNil(harness.viewModel.heldStroke, "let go at pen-up")
        return harness.pixels(of: harness.drawingLayer.texture)
    }

    /// A wandering stroke laid against the ruler draws exactly along it, past its end too;
    /// with the snap off, the wander shows.
    func testAStrokeLaidAgainstTheRulerRunsAlongIt() throws {
        let d = ruler.direction
        let across = CGVector(dx: -d.dy, dy: d.dx)
        func at(_ along: CGFloat, _ off: CGFloat) -> CGPoint {
            CGPoint(x: ruler.start.x + d.dx * along + across.dx * off, y: ruler.start.y + d.dy * along + across.dy * off)
        }
        /// From 150 px along the ruler to 395 (its end is at 367), 0 to 6 px beside it
        let wandering = StrokeFixtures.sampled(duration: 1) { t -> (CGPoint, Float) in
            (at(150 + 245 * CGFloat(t), 3 + 3 * CGFloat(sin(6 * Double.pi * t))), 0.8)
        }
        let held = try drawn(wandering) { $0.ruler = self.ruler }
        // The wander's peaks are a twelfth, five twelfths and nine twelfths along
        for along: CGFloat in [170.4, 252.1, 333.8] {
            XCTAssertGreaterThan(ink(at: at(along, 0), in: held), 0.9, "ink on the ruler \(along) px along")
            XCTAssertEqual(ink(at: at(along, 5.5), in: held), 0, accuracy: 0.001, "none beside it")
        }
        XCTAssertGreaterThan(ink(at: at(385, 0), in: held), 0.9, "past its end, still on its line")
        let free = try drawn(wandering) { var r = self.ruler; r.snaps = false; $0.ruler = r }
        XCTAssertTrue([170.4, 252.1, 333.8].contains { ink(at: at($0, 5.5), in: free) > 0.5 }, "without the snap the wander shows")
    }

    /// A wandering stroke laid against the ellipse draws exactly round it, smoothing and
    /// all; with the snap off, the wander shows.
    func testAStrokeLaidAgainstTheEllipseRunsRoundIt() throws {
        let a = ellipse.radii.width, b = ellipse.radii.height
        /// The point at angle `t` round the ellipse, `off` px out from it, square to it
        func at(_ t: CGFloat, _ off: CGFloat) -> CGPoint {
            let normal = CGVector(dx: cos(t) / a, dy: sin(t) / b)
            let length = hypot(normal.dx, normal.dy)
            return ellipse.world(CGPoint(x: a * cos(t) + off * normal.dx / length, y: b * sin(t) + off * normal.dy / length))
        }
        /// Three quarters of the way round, 0 to 6 px outside it
        let wandering = StrokeFixtures.sampled(duration: 1.5) { t -> (CGPoint, Float) in
            (at(1.5 * .pi * CGFloat(t), 3 + 3 * CGFloat(sin(6 * Double.pi * t))), 0.8)
        }
        let held = try drawn(wandering) { $0.ellipse = self.ellipse }
        let peaks: [CGFloat] = [1, 5, 9].map { 1.5 * .pi * CGFloat($0) / 12 }
        for t in peaks {
            XCTAssertGreaterThan(ink(at: at(t, 0), in: held), 0.9, "ink on the ellipse at \(t)")
            XCTAssertEqual(ink(at: at(t, 5.5), in: held), 0, accuracy: 0.001, "none outside it")
            XCTAssertEqual(ink(at: at(t, -5.5), in: held), 0, accuracy: 0.001, "nor inside: smoothing cut no corner")
        }
        let free = try drawn(wandering) { var e = self.ellipse; e.snaps = false; $0.ellipse = e }
        XCTAssertTrue(peaks.contains { ink(at: at($0, 5.5), in: free) > 0.5 }, "without the snap the wander shows")
    }

    /// Which guide takes a stroke: the ruler or ellipse it lands by; with every size on,
    /// the ellipse through where it lands; else the perspective; none that is hidden or
    /// not snapping.
    func testWhichGuideTakesAStroke() {
        var guides = CanvasGuides()
        guides.perspective = PerspectiveGuide(points: [CGPoint(x: 380, y: 260), CGPoint(x: -300, y: 260)])
        guides.ruler = ruler
        guides.ellipse = ellipse
        func taker(_ p: CGPoint, zoom: CGFloat = 1) -> String {
            switch HeldStroke.landing(at: p, guides: guides, zoom: zoom) {
            case .ruler?: return "ruler"
            case .ellipse(_, let scale)?: return abs(scale - 1) < 1e-9 ? "ellipse" : "ellipse at \(String(format: "%.2f", scale))"
            case .perspective?: return "perspective"
            case nil: return "none"
            }
        }
        let d = ruler.direction
        let besideRuler = CGPoint(x: 200 - 10 * d.dy - 140 * d.dx, y: 150 + 10 * d.dx - 140 * d.dy)
        XCTAssertEqual(ruler.distance(to: besideRuler), 10, accuracy: 1e-6)
        XCTAssertGreaterThan(ellipse.distance(to: besideRuler), 16)
        XCTAssertEqual(taker(besideRuler), "ruler")
        // 12 px outside the ellipse's far side
        let outside = ellipse.world(CGPoint(x: -132, y: 0))
        XCTAssertGreaterThan(ruler.distance(to: outside), 16)
        XCTAssertEqual(taker(outside), "ellipse")
        XCTAssertEqual(taker(outside, zoom: 1.5), "perspective", "18 screen points away is out of reach")
        // Inside the ellipse, 30 px from its outline and from the ruler
        let inside = ellipse.world(CGPoint(x: 0, y: -30))
        XCTAssertGreaterThan(ruler.distance(to: inside), 16)
        XCTAssertEqual(taker(inside), "perspective", "nothing laid against")

        // The ruler runs through the ellipse's middle: put away, so it takes nothing here
        guides.ruler?.isShown = false
        guides.ellipse?.everySize = true
        XCTAssertEqual(taker(inside), "ellipse at 0.50")
        XCTAssertEqual(taker(ellipse.world(CGPoint(x: 0, y: -0.2))), "perspective", "an ellipse too small to follow")

        guides.ellipse?.snaps = false
        XCTAssertEqual(taker(outside), "perspective")
        XCTAssertEqual(taker(besideRuler), "perspective")
        guides.perspective?.snaps = false
        XCTAssertEqual(taker(outside), "none")

        // Within reach of both, the nearer: a level ruler 10 px above a circle's top
        var both = CanvasGuides()
        both.ruler = RulerGuide(start: CGPoint(x: 0, y: 100), end: CGPoint(x: 400, y: 100))
        both.ellipse = EllipseGuide(centre: CGPoint(x: 200, y: 140), radii: CGSize(width: 30, height: 30))
        guides = both
        XCTAssertEqual(taker(CGPoint(x: 200, y: 103)), "ruler")
        XCTAssertEqual(taker(CGPoint(x: 200, y: 107)), "ellipse")
    }

    /// Through the view model: a stroke laid against the ruler starts on it, its predicted
    /// touches follow it; one with every size on follows its ellipse, predicted touches too.
    func testTheViewModelHoldsTheStrokeFromWhereItLands() throws {
        let harness = try EngineHarness(width: 400, height: 300)
        let viewModel = harness.viewModel
        viewModel.guides.ruler = ruler
        let d = ruler.direction
        let landing = CGPoint(x: 200 - 8 * d.dy, y: 150 + 8 * d.dx)
        harness.renderer.beginStroke()
        viewModel.beginStroke(point: sample(landing, 0), input: .pen)
        let first = try XCTUnwrap(viewModel.activePath?.samples.first?.position)
        XCTAssertEqual(first.x, 200, accuracy: 1e-6, "started on the ruler")
        XCTAssertEqual(first.y, 150, accuracy: 1e-6)
        viewModel.predictStroke([sample(CGPoint(x: 260, y: 200), 0.01)])
        let predicted = try XCTUnwrap(viewModel.predictedSamples.first?.position)
        XCTAssertEqual(ruler.distance(to: predicted), 0, accuracy: 1e-6)
        harness.renderer.finalizeStroke()
        viewModel.endStroke()

        var every = ellipse
        every.everySize = true
        viewModel.guides.ruler = nil
        viewModel.guides.ellipse = every
        harness.renderer.beginStroke()
        viewModel.beginStroke(point: sample(ellipse.world(CGPoint(x: 60, y: 0)), 0), input: .pen)
        viewModel.continueStroke(point: sample(ellipse.world(CGPoint(x: 50, y: 20)), 0.02))
        viewModel.predictStroke([sample(ellipse.world(CGPoint(x: 0, y: 50)), 0.03)])
        for p in (viewModel.activePath?.samples.map(\.position) ?? []) + viewModel.predictedSamples.map(\.position) {
            XCTAssertEqual(ellipse.scale(through: p), 0.5, accuracy: 1e-6, "on the half-size ellipse")
        }
        harness.renderer.finalizeStroke()
        viewModel.endStroke()
    }

    // MARK: - Editing

    /// Laid out across the screen, handles picked up and dragged, only the edited guide's
    /// while one is edited and any shown one's otherwise; the document marked changed;
    /// removed.
    func testEditingThroughTheViewModel() throws {
        let viewModel = CanvasViewModel(canvasSize: CGSize(width: 400, height: 300))
        let view = CGSize(width: 400, height: 300)
        // The canvas fills the view one to one
        viewModel.transform.scale = 1
        viewModel.transform.offset = CGPoint(x: -200, y: -150)

        viewModel.editGuide(.ruler, viewSize: view)
        XCTAssertEqual(viewModel.editingGuide, .ruler)
        let laidOut = try XCTUnwrap(viewModel.guides.ruler)
        XCTAssertEqual(laidOut.start.x, 80, accuracy: 1)
        XCTAssertEqual(laidOut.end.x, 320, accuracy: 1)
        XCTAssertEqual(laidOut.angle, 0, accuracy: 1e-6, "level")

        viewModel.markClean()
        XCTAssertTrue(viewModel.guideHandleDown(at: CGPoint(x: 323, y: 152)))
        viewModel.guideHandleDrag(to: CGPoint(x: 333, y: 172))
        viewModel.guideHandleUp()
        XCTAssertEqual(viewModel.guides.ruler!.end.x, laidOut.end.x + 10, accuracy: 1e-9)
        XCTAssertEqual(viewModel.guides.ruler!.end.y, laidOut.end.y + 20, accuracy: 1e-9)
        XCTAssertEqual(viewModel.guides.ruler!.start, laidOut.start, "the other end stays")
        XCTAssertTrue(viewModel.isDirty)

        viewModel.editGuide(.ellipse, viewSize: view)
        XCTAssertEqual(viewModel.editingGuide, .ellipse)
        let e = try XCTUnwrap(viewModel.guides.ellipse)
        XCTAssertEqual(e.centre.x, 200, accuracy: 1)
        XCTAssertEqual(e.centre.y, 150, accuracy: 1)
        XCTAssertEqual(e.radii.width, 80, accuracy: 1)
        XCTAssertEqual(e.degree, 30, accuracy: 1e-6)
        // While the ellipse is edited, the ruler's handles are out of reach
        XCTAssertNil(viewModel.guideHandle(near: viewModel.guides.ruler!.start))
        XCTAssertEqual(viewModel.guideHandle(near: e.centre), .ellipse(.centre))
        viewModel.endGuideEditing()
        XCTAssertEqual(viewModel.guideHandle(near: viewModel.guides.ruler!.start), .ruler(.start), "any shown, editing none")

        viewModel.editGuide(.ruler, viewSize: view)
        viewModel.removeGuide(.ruler)
        XCTAssertNil(viewModel.guides.ruler)
        XCTAssertNil(viewModel.editingGuide, "removing the edited guide ends editing")
        viewModel.changeGuides { $0.ellipse?.isShown = false }
        XCTAssertNil(viewModel.guideHandle(near: e.centre), "a hidden guide has no handles")
        viewModel.editGuide(.ellipse, viewSize: view)
        XCTAssertEqual(viewModel.guides.ellipse?.isShown, true, "editing shows it again")
        XCTAssertEqual(viewModel.guides.ellipse?.centre, e.centre, "where it was")
    }

    // MARK: - Saving

    func testSavedWithTheGuidesAndAbsentFromOlderDocuments() throws {
        var guides = CanvasGuides(verticals: [100])
        guides.ruler = ruler
        var every = ellipse
        every.everySize = true
        guides.ellipse = every
        let data = try JSONEncoder().encode(guides)
        XCTAssertEqual(try JSONDecoder().decode(CanvasGuides.self, from: data), guides)
        let older = try JSONEncoder().encode(CanvasGuides(verticals: [100]))
        let text = String(decoding: older, as: UTF8.self)
        XCTAssertFalse(text.contains("ruler") || text.contains("ellipse"), "none, none written")
        let decoded = try JSONDecoder().decode(CanvasGuides.self, from: older)
        XCTAssertNil(decoded.ruler)
        XCTAssertNil(decoded.ellipse)
    }
}
