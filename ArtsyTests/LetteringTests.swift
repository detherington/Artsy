import XCTest
import CoreText
#if canImport(Artsy)
@testable import Artsy
#endif
@testable import ArtsyEngine

/// Lettering: balloons laid out around their words, drawn into a layer of their own, and
/// the Letter tool that places, picks up, moves and edits them.
final class LetteringTests: XCTestCase {
    private let sentence = "Hello there, how are you today? Fine, I hope."

    private func speech(text: String = "Hello there, how are you today? Fine, I hope.", wrap: CGFloat = 200,
                        tail: CGPoint? = CGPoint(x: 420, y: 300)) -> Balloon {
        Balloon(style: .speech, center: CGPoint(x: 500, y: 500), text: text, wrapWidth: wrap, face: .dialogue,
                fontSize: 20, allCaps: true, tail: tail)
    }

    // MARK: - Layout

    /// The faces are the system's, on the Mac and on iPad alike: each name finds itself,
    /// not a fallback.
    func testTheFacesAreTheSystems() {
        for face in LetteringFace.allCases {
            let font = CTFontCreateWithName(face.postScriptName as CFString, 20, nil)
            XCTAssertEqual(CTFontCopyPostScriptName(font) as String, face.postScriptName, face.rawValue)
        }
    }

    /// A speech balloon's body holds its words, centred where the balloon is, and its tail
    /// reaches the speaker; a tip inside the body draws no tail.
    func testASpeechBalloonHoldsItsWordsAndReachesItsSpeaker() {
        let layout = BalloonLayout(speech())
        XCTAssertEqual(layout.textBox.midX, 500, accuracy: 1)
        XCTAssertEqual(layout.textBox.midY, 500, accuracy: 1)
        let words = layout.textBox.insetBy(dx: 1, dy: 1)
        for corner in [CGPoint(x: words.minX, y: words.minY), CGPoint(x: words.maxX, y: words.maxY),
                       CGPoint(x: words.minX, y: words.maxY), CGPoint(x: words.maxX, y: words.minY)] {
            XCTAssertTrue(layout.body.contains(corner), "the words' corner \(corner) is inside")
        }
        // Just short of the tip, toward the middle, is inside; past it is not
        let nearTip = CGPoint(x: 420 + (500 - 420) * 0.04, y: 300 + (500 - 300) * 0.04)
        XCTAssertTrue(layout.body.contains(nearTip), "the tail reaches its tip")
        XCTAssertFalse(layout.body.contains(CGPoint(x: 410, y: 280)), "and stops there")
        XCTAssertTrue(layout.bounds.contains(CGPoint(x: 420, y: 300)))
        XCTAssertEqual(layout.tailHandle, CGPoint(x: 420, y: 300))
        XCTAssertEqual(layout.widthHandle, CGPoint(x: 600, y: 500), "at the right of the wrap width")

        let tipInside = BalloonLayout(speech(tail: CGPoint(x: 505, y: 500)))
        let noTail = BalloonLayout(speech(tail: nil))
        XCTAssertEqual(tipInside.body.boundingBoxOfPath, noTail.body.boundingBoxOfPath, "a tip inside draws no tail")
        XCTAssertFalse(noTail.bounds.contains(CGPoint(x: 420, y: 300)))
    }

    /// The words wrap at the balloon's width: narrower, they take more lines.
    func testWordsWrapAtTheirWidth() {
        let wide = BalloonLayout(speech(wrap: 600)), narrow = BalloonLayout(speech(wrap: 150))
        XCTAssertLessThanOrEqual(narrow.textBox.width, 150 + 1)
        XCTAssertGreaterThan(narrow.textBox.height, wide.textBox.height * 2, "more lines")
        XCTAssertGreaterThan(narrow.body.boundingBoxOfPath.height, wide.body.boundingBoxOfPath.height)
    }

    /// Each style's body: a thought's cloud, a shout's star and a caption's box hold their
    /// words; a sound effect has no body, and is picked up by its words.
    func testEachStyleHoldsItsWords() {
        for style in BalloonStyle.allCases {
            var balloon = speech()
            balloon.style = style
            let layout = BalloonLayout(balloon)
            XCTAssertTrue(layout.contains(CGPoint(x: 500, y: 500)), "\(style) is picked up at its middle")
            if style == .sound {
                XCTAssertTrue(layout.body.isEmpty, "a sound effect has no body")
            } else {
                let words = layout.textBox.insetBy(dx: 1, dy: 1)
                XCTAssertTrue(layout.body.contains(CGPoint(x: words.minX, y: words.maxY)), "\(style) holds its words")
            }
            XCTAssertEqual(layout.tailHandle != nil, style.hasTail, "\(style)'s tail handle")
        }
        var caption = speech()
        caption.style = .caption
        let box = BalloonLayout(caption).body.boundingBoxOfPath
        XCTAssertEqual(box.midX, 500, accuracy: 1, "a caption's box is round its words")
        XCTAssertFalse(BalloonLayout(caption).bounds.contains(CGPoint(x: 420, y: 300)), "with no tail")
    }

    /// A thought's cloud is its own: scallops of uneven widths, the same each time the
    /// same balloon is drawn, another balloon another shape.
    func testAThoughtCloudIsIrregularAndItsOwn() throws {
        var thought = speech()
        thought.style = .thought
        let body = BalloonLayout(thought).body
        XCTAssertEqual(body, BalloonLayout(thought).body, "the same every time")
        var other = thought
        other.id = UUID()
        XCTAssertNotEqual(BalloonLayout(other).body, body, "another balloon, another cloud")
        // The cusps between the scallops, round the cloud's own outline (before the bubbles)
        var cusps: [CGPoint] = []
        var closed = false
        body.applyWithBlock { element in
            guard !closed else { return }
            switch element.pointee.type {
            case .moveToPoint: cusps.append(element.pointee.points[0])
            case .addCurveToPoint: cusps.append(element.pointee.points[2])
            case .closeSubpath: closed = true
            default: break
            }
        }
        XCTAssertGreaterThanOrEqual(cusps.count, 8)
        let chords = zip(cusps, cusps.dropFirst()).map { hypot($0.x - $1.x, $0.y - $1.y) }
        XCTAssertGreaterThan(try XCTUnwrap(chords.max()) / max(try XCTUnwrap(chords.min()), 0.001), 1.4, "scallops of uneven widths")
    }

    /// Lettered in capitals unless asked not to be; the words keep how they were typed.
    func testCapitals() {
        var balloon = speech(text: "Hello")
        XCTAssertEqual(balloon.displayText, "HELLO")
        balloon.allCaps = false
        XCTAssertEqual(balloon.displayText, "Hello")
        XCTAssertEqual(balloon.text, "Hello")
    }

    func testABalloonSavesAsItIs() throws {
        let balloon = speech()
        let decoded = try JSONDecoder().decode(Balloon.self, from: JSONEncoder().encode(balloon))
        XCTAssertEqual(decoded, balloon)
    }

    // MARK: - The tool

    /// Opaque white where a balloon's body is, nothing where none is.
    private func alpha(_ harness: EngineHarness, _ layer: Layer, _ point: CGPoint) -> Float {
        harness.pixels(of: layer.texture).at(x: Int(point.x), y: Int(point.y)).w
    }

    /// A tap places a balloon on a lettering layer made for it at the top, locked, the
    /// current layer left as it was; the balloon is picked up and the panel asked for the
    /// keyboard. A tap away puts it down; the next tap places another on the same layer.
    func testATapPlacesABalloonOnALetteringLayer() throws {
        let harness = try EngineHarness(width: 800, height: 600)
        let viewModel = harness.viewModel
        let drawing = harness.layerStack.activeLayer
        viewModel.letteringDown(at: CGPoint(x: 400, y: 300), renderer: harness.renderer)
        viewModel.letteringUp(renderer: harness.renderer)

        let layer = try XCTUnwrap(viewModel.letteringLayer)
        XCTAssertTrue(harness.layerStack.layers.last === layer, "at the top")
        XCTAssertEqual(layer.name, "Lettering")
        XCTAssertTrue(layer.isLocked)
        XCTAssertTrue(harness.layerStack.activeLayer === drawing, "drawing goes on where it was")
        XCTAssertEqual(viewModel.balloons.count, 1)
        XCTAssertEqual(viewModel.selectedBalloonID, viewModel.balloons.first?.id)
        XCTAssertTrue(viewModel.balloonWantsKeyboard, "the panel is asked for the keyboard")
        XCTAssertEqual(viewModel.balloons.first?.style, .speech)
        XCTAssertEqual(alpha(harness, layer, CGPoint(x: 400, y: 300)), 1, accuracy: 0.01, "the body is drawn")
        XCTAssertEqual(alpha(harness, layer, CGPoint(x: 100, y: 500)), 0, accuracy: 0.01, "nothing elsewhere")

        viewModel.letteringDown(at: CGPoint(x: 100, y: 500), renderer: harness.renderer)
        XCTAssertNil(viewModel.selectedBalloonID, "a tap away puts it down")
        XCTAssertEqual(viewModel.balloons.count, 1)
        viewModel.balloonStyle = .caption
        viewModel.letteringDown(at: CGPoint(x: 100, y: 500), renderer: harness.renderer)
        XCTAssertEqual(viewModel.balloons.count, 2, "the next tap places another")
        XCTAssertEqual(viewModel.balloons.last?.style, .caption, "in the style chosen")
        XCTAssertEqual(harness.layerStack.layers.filter { $0.lettering != nil }.count, 1, "on the same layer")

        // Undone, the second goes, then the first and its layer
        viewModel.performUndo(renderer: harness.renderer)
        XCTAssertEqual(viewModel.balloons.count, 1)
        viewModel.performUndo(renderer: harness.renderer)
        XCTAssertNil(viewModel.letteringLayer, "the layer made for the first goes with it")
    }

    /// A balloon dragged moves, its tail with it, and is drawn where it is and no longer
    /// where it was; one step undoes the move.
    func testABalloonMovesAndTheMoveUndoes() throws {
        let harness = try EngineHarness(width: 800, height: 600)
        let viewModel = harness.viewModel, renderer = harness.renderer
        viewModel.letteringDown(at: CGPoint(x: 300, y: 300), renderer: renderer)
        viewModel.letteringUp(renderer: renderer)
        let layer = try XCTUnwrap(viewModel.letteringLayer)
        let placed = try XCTUnwrap(viewModel.selectedBalloon)

        viewModel.letteringDown(at: CGPoint(x: 300, y: 300), renderer: renderer)
        viewModel.letteringDrag(to: CGPoint(x: 400, y: 300), renderer: renderer)
        viewModel.letteringDrag(to: CGPoint(x: 500, y: 320), renderer: renderer)
        viewModel.letteringUp(renderer: renderer)
        let moved = try XCTUnwrap(viewModel.selectedBalloon)
        XCTAssertEqual(moved.center, CGPoint(x: 500, y: 320))
        XCTAssertEqual(moved.tail, placed.tail.map { CGPoint(x: $0.x + 200, y: $0.y + 20) }, "the tail goes with it")
        XCTAssertEqual(alpha(harness, layer, CGPoint(x: 500, y: 320)), 1, accuracy: 0.01, "drawn where it is")
        XCTAssertEqual(alpha(harness, layer, CGPoint(x: 300, y: 300)), 0, accuracy: 0.01, "and not where it was")

        viewModel.performUndo(renderer: renderer)
        XCTAssertEqual(viewModel.balloons.first?.center, CGPoint(x: 300, y: 300), "one step undoes the move")
        XCTAssertEqual(alpha(harness, layer, CGPoint(x: 300, y: 300)), 1, accuracy: 0.01)
        XCTAssertEqual(alpha(harness, layer, CGPoint(x: 500, y: 320)), 0, accuracy: 0.01)
    }

    /// The tail's tip and the width handle are taken and dragged; the tap that only picks a
    /// balloon up saves no step.
    func testTheHandlesPointTheTailAndSetTheWidth() throws {
        let harness = try EngineHarness(width: 800, height: 600)
        let viewModel = harness.viewModel, renderer = harness.renderer
        viewModel.letteringDown(at: CGPoint(x: 400, y: 300), renderer: renderer)
        viewModel.letteringUp(renderer: renderer)
        let placed = try XCTUnwrap(viewModel.selectedBalloon)
        let steps = viewModel.undoManager.undoCount

        viewModel.letteringDown(at: CGPoint(x: 400, y: 300), renderer: renderer)
        viewModel.letteringUp(renderer: renderer)
        XCTAssertEqual(viewModel.undoManager.undoCount, steps, "picking up is not a step")

        let tip = try XCTUnwrap(placed.tail)
        viewModel.letteringDown(at: tip, renderer: renderer)
        viewModel.letteringDrag(to: CGPoint(x: 600, y: 120), renderer: renderer)
        viewModel.letteringUp(renderer: renderer)
        XCTAssertEqual(viewModel.selectedBalloon?.tail, CGPoint(x: 600, y: 120))
        XCTAssertEqual(viewModel.selectedBalloon?.center, placed.center, "the body stays")

        let handle = BalloonLayout(try XCTUnwrap(viewModel.selectedBalloon)).widthHandle
        viewModel.letteringDown(at: handle, renderer: renderer)
        viewModel.letteringDrag(to: CGPoint(x: 400 + 150, y: 300), renderer: renderer)
        viewModel.letteringUp(renderer: renderer)
        XCTAssertEqual(viewModel.selectedBalloon?.wrapWidth ?? 0, 300, accuracy: 0.01, "twice the handle's distance from the middle")
        XCTAssertEqual(viewModel.undoManager.undoCount, steps + 2)
    }

    /// Typing into a balloon is one step, however many changes it makes; another kind of
    /// change is a step of its own; deleting takes it off the page and undoes.
    func testThePanelsChangesUndoAsSteps() throws {
        let harness = try EngineHarness(width: 800, height: 600)
        let viewModel = harness.viewModel, renderer = harness.renderer
        viewModel.letteringDown(at: CGPoint(x: 400, y: 300), renderer: renderer)
        let layer = try XCTUnwrap(viewModel.letteringLayer)
        let steps = viewModel.undoManager.undoCount
        for words in ["W", "Wh", "Wha", "What?"] {
            viewModel.changeSelectedBalloon("Edit Words", renderer: renderer) { $0.text = words }
        }
        XCTAssertEqual(viewModel.selectedBalloon?.text, "What?")
        XCTAssertEqual(viewModel.undoManager.undoCount, steps + 1, "typing is one step")
        viewModel.changeSelectedBalloon("Lettering Size", renderer: renderer) { $0.fontSize = 30 }
        XCTAssertEqual(viewModel.undoManager.undoCount, steps + 2)

        viewModel.deleteSelectedBalloon(renderer: renderer)
        XCTAssertTrue(viewModel.balloons.isEmpty)
        XCTAssertNil(viewModel.selectedBalloonID)
        XCTAssertEqual(alpha(harness, layer, CGPoint(x: 400, y: 300)), 0, accuracy: 0.01, "off the page")

        viewModel.performUndo(renderer: renderer)
        XCTAssertEqual(viewModel.balloons.first?.fontSize, 30, "the delete undone")
        viewModel.performUndo(renderer: renderer)
        XCTAssertEqual(viewModel.balloons.first?.text, "What?", "the size undone")
        viewModel.performUndo(renderer: renderer)
        XCTAssertEqual(viewModel.balloons.first?.text, "", "the words undone at once")
    }

    // MARK: - Documents

    /// The balloons save with their layer and come back; a document from before them has
    /// none.
    func testBalloonsSaveWithTheDocument() throws {
        let harness = try EngineHarness(width: 400, height: 300)
        harness.viewModel.letteringDown(at: CGPoint(x: 200, y: 150), renderer: harness.renderer)
        harness.viewModel.changeSelectedBalloon("Edit Words", renderer: harness.renderer) { $0.text = "Saved" }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("ArtsyLettering-\(UUID().uuidString).artsy")
        defer { try? FileManager.default.removeItem(at: url) }
        let saved = expectation(description: "saved")
        CanvasDocument.saveAsync(renderer: harness.renderer, viewModel: harness.viewModel, to: url) { result in
            if case .failure(let error) = result { XCTFail("\(error)") }
            saved.fulfill()
        }
        wait(for: [saved], timeout: 10)
        let opened = try CanvasDocument.load(from: url, metalContext: harness.context)
        let layer = try XCTUnwrap(opened.viewModel.letteringLayer)
        XCTAssertEqual(layer.lettering, harness.viewModel.balloons)
        XCTAssertTrue(layer.isLocked)
        XCTAssertEqual(opened.viewModel.balloons.first?.text, "Saved")
    }
}
