import XCTest
import CoreText
#if canImport(Artsy)
@testable import Artsy
#endif
@testable import ArtsyEngine

/// Drawn lettering fonts: strokes traced into outlines, written as TrueType that Core Text
/// reads, kept in a library, set in balloons, carried in documents, and drawn in the Font
/// Studio.
final class DrawnFontTests: XCTestCase {
    private var directory: URL!
    private var library: DrawnFontLibrary!
    private var sharedLibrary: DrawnFontLibrary!

    override func setUp() {
        super.setUp()
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("ArtsyFonts-\(UUID().uuidString)")
        library = DrawnFontLibrary(directory: directory)
        sharedLibrary = DrawnFontLibrary.shared
        DrawnFontLibrary.shared = library
    }

    override func tearDown() {
        DrawnFontLibrary.shared = sharedLibrary
        try? FileManager.default.removeItem(at: directory)
        super.tearDown()
    }

    // MARK: - Strokes

    /// A straight stroke from `a` to `b`, a point every ten units.
    private func line(_ a: CGPoint, _ b: CGPoint, pen: GlyphPen = .marker, weight: CGFloat = 80) -> GlyphStroke {
        let steps = max(1, Int((hypot(b.x - a.x, b.y - a.y) / 10).rounded()))
        let points = (0...steps).map { i -> GlyphPoint in
            let t = CGFloat(i) / CGFloat(steps)
            return GlyphPoint(x: (a.x + (b.x - a.x) * t).rounded(), y: (a.y + (b.y - a.y) * t).rounded())
        }
        return GlyphStroke(pen: pen, weight: weight, points: points)
    }

    private var letterI: DrawnGlyph { DrawnGlyph(strokes: [line(CGPoint(x: 150, y: 0), CGPoint(x: 150, y: 700))]) }

    private var letterA: DrawnGlyph {
        DrawnGlyph(strokes: [line(CGPoint(x: 0, y: 0), CGPoint(x: 250, y: 700)), line(CGPoint(x: 250, y: 700), CGPoint(x: 500, y: 0)),
                             line(CGPoint(x: 120, y: 250), CGPoint(x: 380, y: 250))])
    }

    /// A ring: a stroke round a circle, closed.
    private var letterO: DrawnGlyph {
        let points = (0...72).map { k -> GlyphPoint in
            let a = CGFloat(k) / 72 * 2 * .pi
            return GlyphPoint(x: (300 + 300 * cos(a)).rounded(), y: (350 + 350 * sin(a)).rounded())
        }
        return DrawnGlyph(strokes: [GlyphStroke(pen: .marker, weight: 80, points: points)])
    }

    private func font(_ glyphs: [String: DrawnGlyph], name: String = "Test Hand") -> DrawnFont {
        DrawnFont(name: name, glyphs: glyphs)
    }

    /// A marker's stroke covers its width either side of the way it went, round at its ends;
    /// its clean outline is one contour, clockwise as TrueType wants.
    func testAStrokeCoversItsPenWidth() {
        let stroke = line(CGPoint(x: 100, y: 350), CGPoint(x: 600, y: 350))
        let path = GlyphOutline.path(of: stroke)
        XCTAssertTrue(path.contains(CGPoint(x: 350, y: 385)), "within the width")
        XCTAssertFalse(path.contains(CGPoint(x: 350, y: 395)), "and not past it")
        XCTAssertTrue(path.contains(CGPoint(x: 65, y: 350)), "a round end")
        XCTAssertFalse(path.contains(CGPoint(x: 55, y: 350)))
        XCTAssertFalse(path.contains(CGPoint(x: 72, y: 382)), "round, not square")
        let contours = GlyphOutline.contours(of: DrawnGlyph(strokes: [stroke]))
        XCTAssertEqual(contours.count, 1)
        XCTAssertLessThan(GlyphOutline.signedArea(contours[0].map { CGPoint(x: $0.x, y: $0.y) }), 0, "clockwise")
    }

    /// A letter with a hole: the outline clockwise, the hole inside it anticlockwise; and a
    /// glyph of a few hundred points is traced quickly.
    func testALetterWithAHoleWindsItsHoleTheOtherWay() {
        let started = Date()
        let contours = GlyphOutline.contours(of: letterO)
        XCTAssertLessThan(Date().timeIntervalSince(started), 1, "traced in well under a second")
        XCTAssertEqual(contours.count, 2)
        let areas = contours.map { GlyphOutline.signedArea($0.map { CGPoint(x: $0.x, y: $0.y) }) }.sorted { abs($0) > abs($1) }
        XCTAssertLessThan(areas[0], 0, "the outline clockwise")
        XCTAssertGreaterThan(areas[1], 0, "the hole anticlockwise")
    }

    /// The brush narrows as the pen lightens; the chisel is broad one way and thin the other.
    func testTheBrushFollowsPressureAndTheChiselItsNib() {
        XCTAssertEqual(GlyphPen.brush.width(weight: 100, pressure: 0), 30, accuracy: 0.01)
        XCTAssertEqual(GlyphPen.brush.width(weight: 100, pressure: 1), 100, accuracy: 0.01)
        XCTAssertEqual(GlyphPen.marker.width(weight: 100, pressure: 0), 100)
        let across = GlyphOutline.path(of: line(CGPoint(x: 100, y: 300), CGPoint(x: 600, y: 300), pen: .chisel, weight: 100))
        let down = GlyphOutline.path(of: line(CGPoint(x: 300, y: 0), CGPoint(x: 300, y: 600), pen: .chisel, weight: 100))
        XCTAssertLessThan(across.boundingBoxOfPath.height, down.boundingBoxOfPath.width * 0.8,
                          "thinner drawn along the nib's slant than across it")
    }

    /// A stroke settles smoother: points evenly spaced, its wobble eased, its ends kept.
    func testSmoothingEvensTheStrokeAndKeepsItsEnds() {
        let shaky = GlyphStroke(pen: .marker, weight: 60, points: (0..<200).map {
            GlyphPoint(x: CGFloat($0) * 2, y: 300 + ($0.isMultiple(of: 2) ? 3 : -3))
        })
        let smooth = shaky.smoothed()
        XCTAssertEqual(smooth.points.first, shaky.points.first)
        XCTAssertEqual(smooth.points.last, shaky.points.last)
        let inner = smooth.points.dropFirst(3).dropLast(3)
        XCTAssertLessThan(inner.map { abs($0.y - 300) }.max() ?? 0, 1.5, "the wobble eased")
        let gaps = zip(smooth.points, smooth.points.dropFirst()).map { hypot($1.x - $0.x, $1.y - $0.y) }.dropLast()
        XCTAssertLessThan((gaps.max() ?? 0) - (gaps.min() ?? 0), 2.5, "evenly spaced")
    }

    // MARK: - The font file

    private func ctFont(_ data: Data, size: CGFloat = 1000) throws -> CTFont {
        let descriptor = try XCTUnwrap(CTFontManagerCreateFontDescriptorFromData(data as CFData), "Core Text reads it")
        return CTFontCreateWithFontDescriptor(descriptor, size, nil)
    }

    private func glyphs(_ string: String, in font: CTFont) -> [CGGlyph] {
        let characters = Array(string.utf16)
        var glyphs = [CGGlyph](repeating: 0, count: characters.count)
        CTFontGetGlyphsForCharacters(font, characters, &glyphs, characters.count)
        return glyphs
    }

    /// Core Text reads the font and sets the letters as drawn: their ink, their spacing, the
    /// guides' metrics. A capital drawn answers for its small letter, and a small letter for
    /// its capital; a character not drawn is not in the font.
    func testTheFontFileSetsTheLettersAsDrawn() throws {
        let drawn = font(["A": letterA, "I": letterI, "o": letterO])
        let font = try ctFont(XCTUnwrap(DrawnFontFile.trueType(for: drawn)))
        let found = glyphs("AaIiOoB", in: font)
        XCTAssertNotEqual(found[0], 0, "A")
        XCTAssertEqual(found[1], found[0], "a in the A")
        XCTAssertEqual(found[3], found[2], "i in the I")
        XCTAssertNotEqual(found[5], 0, "o")
        XCTAssertEqual(found[4], found[5], "O in the o")
        XCTAssertEqual(found[6], 0, "B is not drawn")

        // I: a stroke 80 wide from the baseline to the cap height, set 50 from each side
        let ink = try XCTUnwrap(CTFontCreatePathForGlyph(font, found[2], nil)).boundingBoxOfPath
        XCTAssertEqual(ink.minX, 50, accuracy: 1.5)
        XCTAssertEqual(ink.width, 80, accuracy: 2)
        XCTAssertEqual(ink.minY, -40, accuracy: 2)
        XCTAssertEqual(ink.maxY, 740, accuracy: 2)
        var advance = CGSize.zero
        CTFontGetAdvancesForGlyphs(font, .horizontal, [found[2]], &advance, 1)
        XCTAssertEqual(advance.width, ink.width + 100, accuracy: 2)

        // A's crossbar is ink, the room under it is not (its ink starts 40 left of 0, set 50 in)
        let a = try XCTUnwrap(CTFontCreatePathForGlyph(font, found[0], nil))
        XCTAssertTrue(a.contains(CGPoint(x: 340, y: 250)), "the crossbar")
        XCTAssertFalse(a.contains(CGPoint(x: 340, y: 120)), "under it")
        XCTAssertFalse(a.contains(CGPoint(x: 340, y: 420)), "the hole over it")

        XCTAssertEqual(CTFontGetCapHeight(font), 700, accuracy: 0.5)
        XCTAssertEqual(CTFontGetAscent(font), 900, accuracy: 0.5)
        XCTAssertEqual(CTFontGetDescent(font), 200, accuracy: 0.5)
    }

    /// An exported font is named for itself; one for use carries a digest that changes with it.
    func testAnExportedFontIsNamedForItself() throws {
        let drawn = font(["I": letterI], name: "My Hand 2")
        let exported = try ctFont(XCTUnwrap(DrawnFontFile.trueType(for: drawn, forExport: true)))
        XCTAssertEqual(CTFontCopyPostScriptName(exported) as String, "MyHand2-Regular")
        XCTAssertEqual(CTFontCopyFamilyName(exported) as String, "My Hand 2")
        XCTAssertEqual(DrawnFontFile.fileName(of: drawn), "My Hand 2.ttf")

        let used = try ctFont(XCTUnwrap(DrawnFontFile.trueType(for: drawn)))
        var wider = drawn
        wider.spacing = 80
        let usedWider = try ctFont(XCTUnwrap(DrawnFontFile.trueType(for: wider)))
        XCTAssertTrue((CTFontCopyPostScriptName(used) as String).hasPrefix("ArtsyDrawn-"))
        XCTAssertNotEqual(CTFontCopyPostScriptName(used) as String, CTFontCopyPostScriptName(usedWider) as String)
        XCTAssertNil(DrawnFontFile.trueType(for: font([:])), "nothing drawn, no font")
    }

    /// A font is saved compactly and read back as it was.
    func testAFontRoundTrips() throws {
        let drawn = font(["A": letterA, "o": letterO])
        let data = try JSONEncoder().encode(drawn)
        XCTAssertEqual(try JSONDecoder().decode(DrawnFont.self, from: data), drawn)
        XCTAssertLessThan(data.count, 12_000, "points in a row of numbers")
    }

    // MARK: - The library

    /// The library saves a font and its compiled file, registers it for balloons, reads both
    /// back on the next launch, and deletes them.
    func testTheLibrarySavesCompilesAndRegisters() throws {
        var drawn = library.newFont(named: "Test Hand")
        drawn.glyphs["I"] = letterI
        library.update(drawn)
        library.waitUntilCompiled()
        XCTAssertTrue(DrawnFonts.isRegistered(drawn.id))
        let file = directory.appendingPathComponent("\(drawn.id.uuidString).artsyfont")
        let compiled = directory.appendingPathComponent("\(drawn.id.uuidString).ttf")
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: compiled.path))

        DrawnFonts.unregister(drawn.id)
        let again = DrawnFontLibrary(directory: directory)
        again.waitUntilCompiled()
        XCTAssertEqual(again.fonts.map(\.id), [drawn.id])
        XCTAssertEqual(again.fonts.first?.glyphs, drawn.glyphs)
        XCTAssertTrue(DrawnFonts.isRegistered(drawn.id), "from its compiled file")

        again.delete(drawn.id)
        again.waitUntilCompiled()
        XCTAssertFalse(DrawnFonts.isRegistered(drawn.id))
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: compiled.path))
        XCTAssertNotNil(library.duplicate(library.newFont().id), "a copy")
        XCTAssertEqual(library.fonts.map(\.name), ["My Lettering", "My Lettering copy", "Test Hand"])
    }

    // MARK: - Balloons

    private func balloon(_ text: String, font id: UUID?) -> Balloon {
        Balloon(style: .caption, center: CGPoint(x: 500, y: 500), text: text, wrapWidth: 2000, face: .clean, drawnFont: id,
                fontSize: 100, allCaps: true)
    }

    /// A balloon set in a drawn font takes its letters' widths; a character the font lacks is
    /// set in the balloon's face, and a balloon whose font is gone is set in its face alone.
    func testABalloonIsSetInItsDrawnFont() throws {
        let drawn = font(["I": letterI])
        XCTAssertTrue(DrawnFonts.register(try XCTUnwrap(DrawnFontFile.trueType(for: drawn)), for: drawn.id))
        defer { DrawnFonts.unregister(drawn.id) }
        // I is 80 wide and 50 either side: 18 at a size of 100
        XCTAssertEqual(BalloonLayout(balloon("III", font: drawn.id)).textBox.width, 54, accuracy: 1.5)
        let faceOnly = BalloonLayout(balloon("III", font: nil)).textBox.width
        XCTAssertNotEqual(faceOnly, 54, accuracy: 3, "the face sets it otherwise")
        XCTAssertEqual(BalloonLayout(balloon("III", font: UUID())).textBox.width, faceOnly, "a font that is gone")
        let lacking = BalloonLayout(balloon("B", font: drawn.id)).textBox.width
        XCTAssertEqual(lacking, BalloonLayout(balloon("B", font: nil)).textBox.width, accuracy: 1, "B in the face")
    }

    /// Balloons from before drawn fonts read with none; one set in a font keeps it.
    func testABalloonKeepsItsFont() throws {
        let id = UUID()
        let data = try JSONEncoder().encode(balloon("Hi", font: id))
        XCTAssertEqual(try JSONDecoder().decode(Balloon.self, from: data).drawnFont, id)
        var old = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        old["drawnFont"] = nil
        let before = try JSONDecoder().decode(Balloon.self, from: JSONSerialization.data(withJSONObject: old))
        XCTAssertNil(before.drawnFont)
    }

    /// A balloon placed with a drawn font chosen is set in it; when the font changes, the
    /// canvas sets the balloon again and has something to save.
    func testChangingAFontSetsItsBalloonsAgain() throws {
        var drawn = library.newFont(named: "Shout")
        drawn.glyphs["I"] = letterI
        let drawnFirst = expectation(forNotification: DrawnFontLibrary.fontsDidChange, object: library)
        library.update(drawn)
        wait(for: [drawnFirst], timeout: 5)

        let harness = try EngineHarness(width: 400, height: 300)
        let viewModel = harness.viewModel
        viewModel.balloonDrawnFont = drawn.id
        viewModel.letteringDown(at: CGPoint(x: 200, y: 150), renderer: harness.renderer)
        viewModel.letteringUp(renderer: harness.renderer)
        viewModel.changeSelectedBalloon("Edit Words", renderer: harness.renderer) { $0.text = "III" }
        let placed = try XCTUnwrap(viewModel.balloons.first)
        XCTAssertEqual(placed.drawnFont, drawn.id)
        let narrow = BalloonLayout(placed).textBox.width

        viewModel.markClean()
        let revision = viewModel.letteringRevision
        let told = expectation(forNotification: DrawnFontLibrary.fontsDidChange, object: library) { note in
            (note.userInfo?["ids"] as? Set<UUID>)?.contains(drawn.id) == true
        }
        drawn.glyphs["I"] = DrawnGlyph(strokes: [line(CGPoint(x: 150, y: 0), CGPoint(x: 150, y: 700), weight: 200)])
        library.update(drawn)
        wait(for: [told], timeout: 5)
        XCTAssertGreaterThan(BalloonLayout(placed).textBox.width, narrow, "the wider letters")
        XCTAssertGreaterThan(viewModel.letteringRevision, revision, "set again")
        XCTAssertTrue(viewModel.isDirty)

        // A new name alone sets nothing differently
        let renamed = expectation(forNotification: DrawnFontLibrary.fontsDidChange, object: library)
        renamed.isInverted = true
        drawn.name = "Shouting"
        library.update(drawn)
        wait(for: [renamed], timeout: 0.5)
    }

    /// A document carries the drawn fonts its balloons are set in; opened where the library
    /// lacks them, they join it and are set again.
    func testDocumentsCarryTheirDrawnFonts() throws {
        var drawn = library.newFont(named: "Carried")
        drawn.glyphs["A"] = letterA
        library.update(drawn)
        library.waitUntilCompiled()
        let harness = try EngineHarness(width: 400, height: 300)
        harness.viewModel.balloonDrawnFont = drawn.id
        harness.viewModel.letteringDown(at: CGPoint(x: 200, y: 150), renderer: harness.renderer)
        harness.viewModel.letteringUp(renderer: harness.renderer)
        harness.viewModel.changeSelectedBalloon("Edit Words", renderer: harness.renderer) { $0.text = "A" }

        let url = FileManager.default.temporaryDirectory.appendingPathComponent("ArtsyFonts-\(UUID().uuidString).artsy")
        defer { try? FileManager.default.removeItem(at: url) }
        let saved = expectation(description: "saved")
        CanvasDocument.saveAsync(renderer: harness.renderer, viewModel: harness.viewModel, to: url) { result in
            if case .failure(let error) = result { XCTFail("\(error)") }
            saved.fulfill()
        }
        wait(for: [saved], timeout: 10)
        XCTAssertEqual(try CanvasDocument.read(from: url).fonts?.map(\.id), [drawn.id])

        // Somewhere the font was never drawn
        let elsewhere = directory.appendingPathComponent("Elsewhere")
        let other = DrawnFontLibrary(directory: elsewhere)
        DrawnFontLibrary.shared = other
        DrawnFonts.unregister(drawn.id)
        let opened = try CanvasDocument.load(from: url, metalContext: harness.context)
        other.waitUntilCompiled()
        XCTAssertEqual(other.fonts.map(\.id), [drawn.id])
        XCTAssertEqual(other.fonts.first?.glyphs, drawn.glyphs)
        XCTAssertTrue(DrawnFonts.isRegistered(drawn.id))
        XCTAssertEqual(opened.viewModel.balloons.first?.drawnFont, drawn.id)
    }

    #if canImport(Artsy)
    // MARK: - The Font Studio

    /// The studio draws on the character in hand, undoes and redoes stroke by stroke, clears,
    /// and turns from character to character round the end.
    func testTheStudioDrawsUndoesAndTurns() throws {
        let model = FontStudioModel(library: library)
        XCTAssertNil(model.font, "no fonts yet")
        model.newFont()
        let id = try XCTUnwrap(model.fontID)
        XCTAssertEqual(model.character, "A")
        model.add(line(CGPoint(x: 0, y: 0), CGPoint(x: 250, y: 700)))
        model.add(line(CGPoint(x: 250, y: 700), CGPoint(x: 500, y: 0)))
        XCTAssertEqual(model.glyph?.strokes.count, 2)
        model.step(by: 1)
        XCTAssertEqual(model.character, "B")
        model.undo()
        XCTAssertEqual(model.character, "A", "undo brings the character back up")
        XCTAssertEqual(library.font(id: id)?.glyph(for: "A")?.strokes.count, 1)
        model.redo()
        XCTAssertEqual(model.glyph?.strokes.count, 2)
        model.clear()
        XCTAssertNil(model.glyph)
        model.undo()
        XCTAssertEqual(model.glyph?.strokes.count, 2, "clearing undone")
        XCTAssertTrue(model.canRedo)

        model.step(by: -1)
        XCTAssertEqual(model.character, DrawnFont.characters.last, "round the end")
        model.select("’")
        XCTAssertEqual(model.character, "'", "a curly quote turns to the straight one")
        model.select("x")
        XCTAssertEqual(model.character, "x")
        model.setSpacing(90)
        model.rename("Studio Hand")
        XCTAssertEqual(library.font(id: id)?.spacing, 90)
        XCTAssertEqual(library.font(id: id)?.name, "Studio Hand")
        library.waitUntilCompiled()
        let file = try XCTUnwrap(model.exportedFile())
        XCTAssertEqual(file.name, "Studio Hand")
        XCTAssertEqual(CTFontCopyFamilyName(try ctFont(file.data)) as String, "Studio Hand")

        model.deleteFont()
        XCTAssertNil(model.fontID)
        XCTAssertTrue(library.fonts.isEmpty)
    }
    #endif
}
