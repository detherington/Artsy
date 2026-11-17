import XCTest
#if canImport(Artsy)
@testable import Artsy
#endif
@testable import ArtsyEngine

/// Balloons drawn by hand: a sketch fitted into an outline and the ellipse inside it, a
/// drawn point taken for the tail, the layout drawing the outline with the usual tail and
/// growing it for words, saving, and the Letter tool drawing one.
final class DrawnBalloonTests: XCTestCase {
    private let size: CGFloat = 20
    private let middle = CGPoint(x: 400, y: 300)

    /// A wobbly loop round `middle`, 360 × 220 before its wobbles, drawn from angle 0 a
    /// little past a full turn so its ends overlap, or `turn` of the way round; with a point
    /// sticking out to twice its reach at `spike` radians if given.
    private func sketch(turn: CGFloat = 1.03, a: CGFloat = 180, b: CGFloat = 110, spike: CGFloat? = nil) -> [CGPoint] {
        // Evenly round, and exactly at the point's tip
        let angles = ((0...200).map { 2 * .pi * turn * CGFloat($0) / 200 } + (spike.map { [$0] } ?? [])).sorted()
        return angles.map { t -> CGPoint in
            var reach = 1 + 0.06 * sin(5 * t) + 0.03 * sin(11 * t + 1)
            if let spike {
                let off = abs(atan2(sin(t - spike), cos(t - spike)))
                if off < 0.12 { reach = 1 + (2 - 1) * (1 - off / 0.12) }
            }
            return CGPoint(x: middle.x + a * reach * cos(t), y: middle.y + b * reach * sin(t))
        }
    }

    // MARK: - Fitting

    /// A wobbly loop fits: round its middle, the ellipse inside touching it and inside every
    /// point of it, and the outline as drawn, wobbles and all.
    func testAWobblyLoopFitsAsDrawn() throws {
        let drawn = sketch()
        let fitted = try XCTUnwrap(BalloonSketch.fit(drawn, size: size, takesTail: true))
        XCTAssertNil(fitted.tail, "no point drawn, no tail")
        XCTAssertEqual(fitted.center.x, middle.x, accuracy: 8)
        XCTAssertEqual(fitted.center.y, middle.y, accuracy: 8)
        let reaches = fitted.outline.points.map { hypot($0.x, $0.y) }
        XCTAssertGreaterThanOrEqual(reaches.min()!, 1 - 1e-9, "every point on or outside the ellipse inside")
        XCTAssertLessThan(reaches.min()!, 1.0001, "which touches it")
        XCTAssertGreaterThan(reaches.max()! / reaches.min()!, 1.1, "the wobbles kept")
        let r = fitted.outline.radii
        XCTAssertTrue((150...180).contains(r.width), "\(r.width) across, inside the drawn 360")
        XCTAssertTrue((90...110).contains(r.height), "\(r.height) up, inside the drawn 220")
        // Laid back at the drawn size, the outline runs where the pen did
        let laid = fitted.outline.points.map { CGPoint(x: fitted.center.x + $0.x * r.width, y: fitted.center.y + $0.y * r.height) }
        func distance(_ p: CGPoint, toSegment a: CGPoint, _ b: CGPoint) -> CGFloat {
            let ab = CGVector(dx: b.x - a.x, dy: b.y - a.y)
            let t = max(0, min(1, ((p.x - a.x) * ab.dx + (p.y - a.y) * ab.dy) / max(ab.dx * ab.dx + ab.dy * ab.dy, 1e-9)))
            return hypot(p.x - (a.x + ab.dx * t), p.y - (a.y + ab.dy * t))
        }
        for p in drawn.prefix(195) {
            let nearest = zip(laid, laid.dropFirst() + [laid[0]]).map { distance(p, toSegment: $0.0, $0.1) }.min()!
            XCTAssertLessThan(nearest, 2.5, "drawn at \(p)")
        }
    }

    /// A loop whose ends stop short of each other closes; an open arc and a loop too small
    /// to hold a word make no balloon.
    func testGapsCloseAndOpenOrTinyStrokesDoNot() {
        XCTAssertNotNil(BalloonSketch.fit(sketch(turn: 0.93), size: size, takesTail: true), "a seventh of a turn short")
        XCTAssertNil(BalloonSketch.fit(sketch(turn: 0.5), size: size, takesTail: true), "half a turn is no loop")
        XCTAssertNil(BalloonSketch.fit(sketch(a: 20, b: 15), size: size, takesTail: true), "too small for a word")
        XCTAssertNil(BalloonSketch.fit(Array(sketch().prefix(5)), size: size, takesTail: true))
    }

    /// A point drawn sticking out of the loop is its tail: the tip where the point was, the
    /// base as wide as drawn, and the outline without it. A caption keeps it as drawn.
    func testADrawnPointBecomesTheTail() throws {
        let spike = 1.25 * CGFloat.pi
        let drawn = sketch(spike: spike)
        let fitted = try XCTUnwrap(BalloonSketch.fit(drawn, size: size, takesTail: true))
        let tip = try XCTUnwrap(fitted.tail, "the point taken for a tail")
        let expected = CGPoint(x: middle.x + 360 * cos(spike), y: middle.y + 220 * sin(spike))
        XCTAssertLessThan(hypot(tip.x - expected.x, tip.y - expected.y), 6, "its tip where the point was")
        let base = try XCTUnwrap(fitted.tailBase)
        XCTAssertTrue((1.0...3.5).contains(base), "\(base) sizes: about the drawn base's 35 px")
        XCTAssertLessThan(fitted.outline.points.map { hypot($0.x, $0.y) }.max()!, 1.4, "the point gone from the outline")

        let caption = try XCTUnwrap(BalloonSketch.fit(drawn, size: size, takesTail: false))
        XCTAssertNil(caption.tail)
        XCTAssertGreaterThan(caption.outline.points.map { hypot($0.x, $0.y) }.max()!, 1.6, "kept, for a kind with no tail")
    }

    // MARK: - Drawing it

    private func balloon(_ fitted: BalloonSketch.Fitted, text: String = "") -> Balloon {
        var balloon = Balloon.new(.speech, at: fitted.center, face: .dialogue, fontSize: size, allCaps: true)
        balloon.drawn = fitted.outline
        balloon.wrapWidth = max(size * 2.5, 2 * (fitted.outline.radii.width / 1.32 - size * 0.5))
        balloon.text = text
        balloon.tail = fitted.tail
        balloon.look.tailBase = fitted.tailBase
        return balloon
    }

    /// The body is the drawn shape at the drawn size with the usual tail joined on, reaching
    /// its tip, with a base diamond; words that outgrow it stretch it, and it holds them.
    func testTheLayoutDrawsTheDrawnBodyWithTheUsualTail() throws {
        let fitted = try XCTUnwrap(BalloonSketch.fit(sketch(spike: 1.25 * .pi), size: size, takesTail: true))
        let empty = BalloonLayout(balloon(fitted))
        let r = fitted.outline.radii, c = fitted.center
        for p in [CGPoint(x: c.x + r.width * 0.95, y: c.y), CGPoint(x: c.x, y: c.y + r.height * 0.95),
                  CGPoint(x: c.x - r.width * 0.95, y: c.y)] {
            XCTAssertTrue(empty.body.contains(p), "drawn size, though it holds no words: \(p)")
        }
        XCTAssertFalse(empty.body.contains(CGPoint(x: c.x + r.width * 1.5, y: c.y)), "and no larger")
        let tip = try XCTUnwrap(fitted.tail)
        let reach = empty.body.boundingBoxOfPath
        XCTAssertEqual(reach.minX, tip.x, accuracy: 3, "the tail reaches its tip, down and to the left")
        XCTAssertEqual(reach.minY, tip.y, accuracy: 3)
        XCTAssertNotNil(empty.baseHandle, "with its base diamond")
        XCTAssertNotNil(empty.baseSize(draggedTo: CGPoint(x: tip.x + 40, y: tip.y)))

        let words = String(repeating: "THE WORDS GO ON AND ON ", count: 12)
        let full = BalloonLayout(balloon(fitted, text: words))
        XCTAssertGreaterThan(full.body.boundingBoxOfPath.height, empty.body.boundingBoxOfPath.height * 1.2, "stretched to hold them")
        for corner in [CGPoint(x: full.textBox.minX, y: full.textBox.midY), CGPoint(x: full.textBox.maxX, y: full.textBox.midY),
                       CGPoint(x: full.textBox.midX, y: full.textBox.maxY), CGPoint(x: full.textBox.midX, y: full.textBox.minY)] {
            XCTAssertTrue(full.body.contains(corner), "the words inside: \(corner)")
        }
    }

    func testADrawnOutlineIsSavedAndAPlainBalloonWritesNone() throws {
        let fitted = try XCTUnwrap(BalloonSketch.fit(sketch(), size: size, takesTail: true))
        let drawn = balloon(fitted, text: "HI")
        XCTAssertEqual(try JSONDecoder().decode(Balloon.self, from: JSONEncoder().encode(drawn)), drawn)
        let plain = Balloon.new(.speech, at: middle, face: .dialogue, fontSize: size, allCaps: true)
        XCTAssertFalse(String(decoding: try JSONEncoder().encode(plain), as: UTF8.self).contains("drawn"))
    }

    // MARK: - The tool

    private func drag(_ points: [CGPoint], _ viewModel: CanvasViewModel, _ renderer: CanvasRenderer) {
        viewModel.letteringDown(at: points[0], renderer: renderer)
        for p in points.dropFirst() { viewModel.letteringDrag(to: p, renderer: renderer) }
        viewModel.letteringUp(renderer: renderer)
    }

    /// A loop drawn on empty page is a drawn balloon, one step, picked up; a tap still
    /// places a plain one when it lifts; an open scribble places nothing; drawn with the
    /// sound kind it is a shout; a shape chosen in the panel replaces the outline.
    func testTheLetterToolDrawsABalloon() throws {
        let harness = try EngineHarness(width: 800, height: 600)
        let viewModel = harness.viewModel, renderer = harness.renderer
        let before = viewModel.undoManager.undoCount
        let loop = sketch(spike: 1.25 * .pi)
        viewModel.letteringDown(at: loop[0], renderer: renderer)
        for p in loop[1..<40] { viewModel.letteringDrag(to: p, renderer: renderer) }
        XCTAssertEqual(viewModel.balloonSketch.count, 40, "the sketch shows as it is drawn")
        for p in loop[40...] { viewModel.letteringDrag(to: p, renderer: renderer) }
        viewModel.letteringUp(renderer: renderer)
        XCTAssertTrue(viewModel.balloonSketch.isEmpty)
        let drawn = try XCTUnwrap(viewModel.selectedBalloon, "drawn and picked up")
        XCTAssertNotNil(drawn.drawn)
        XCTAssertEqual(drawn.style, .speech)
        XCTAssertNotNil(drawn.tail)
        XCTAssertNotNil(drawn.look.tailBase)
        XCTAssertTrue(viewModel.balloonWantsKeyboard)
        XCTAssertEqual(viewModel.undoManager.undoCount, before + 1, "one step")

        // A tap away puts it down; the next tap places a plain one as it lifts
        drag([CGPoint(x: 60, y: 560)], viewModel, renderer)
        XCTAssertNil(viewModel.selectedBalloonID)
        viewModel.letteringDown(at: CGPoint(x: 60, y: 560), renderer: renderer)
        XCTAssertEqual(viewModel.balloons.count, 1, "not on the press")
        viewModel.letteringUp(renderer: renderer)
        XCTAssertEqual(viewModel.balloons.count, 2, "on the lift")
        XCTAssertNil(viewModel.balloons.last?.drawn)

        // An open scribble makes nothing
        drag([CGPoint(x: 700, y: 560)], viewModel, renderer)
        drag((0...30).map { CGPoint(x: 600 + CGFloat($0) * 6, y: 80 + 20 * sin(CGFloat($0))) }, viewModel, renderer)
        XCTAssertEqual(viewModel.balloons.count, 2)

        // Drawn with the sound kind: a shout
        viewModel.balloonStyle = .sound
        drag(sketch(a: 120, b: 80).map { CGPoint(x: $0.x - 150, y: $0.y + 180) }, viewModel, renderer)
        XCTAssertEqual(viewModel.selectedBalloon?.style, .shout)
        XCTAssertNotNil(viewModel.selectedBalloon?.drawn)

        // A shape chosen for it replaces its outline, as a step
        let steps = viewModel.undoManager.undoCount
        var burst = try XCTUnwrap(viewModel.selectedBalloon).look
        burst.shape = .burst
        viewModel.setBalloonLook(burst, as: "Balloon Shape", replacingDrawn: true, renderer: renderer)
        XCTAssertNil(viewModel.selectedBalloon?.drawn)
        XCTAssertEqual(viewModel.undoManager.undoCount, steps + 1)
    }
}
