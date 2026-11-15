import XCTest
import CoreText
#if canImport(Artsy)
@testable import Artsy
#endif
@testable import ArtsyEngine

/// A drawn font's kerning, its letters' other versions rotated through, its bold and italic,
/// and font files imported: an Artsy font back as drawn, any other set as it is.
final class DrawnFontFamilyTests: XCTestCase {
    private var directory: URL!
    private var library: DrawnFontLibrary!
    private var sharedLibrary: DrawnFontLibrary!

    override func setUp() {
        super.setUp()
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("ArtsyFontFamily-\(UUID().uuidString)")
        library = DrawnFontLibrary(directory: directory)
        sharedLibrary = DrawnFontLibrary.shared
        DrawnFontLibrary.shared = library
    }

    override func tearDown() {
        DrawnFontLibrary.shared = sharedLibrary
        try? FileManager.default.removeItem(at: directory)
        super.tearDown()
    }

    // MARK: - Letters

    private func line(_ points: [(CGFloat, CGFloat)], weight: CGFloat = 80) -> GlyphStroke {
        var out: [GlyphPoint] = []
        for (a, b) in zip(points, points.dropFirst()) {
            let steps = max(1, Int((hypot(b.0 - a.0, b.1 - a.1) / 10).rounded()))
            for i in 0..<steps {
                let t = CGFloat(i) / CGFloat(steps)
                out.append(GlyphPoint(x: (a.0 + (b.0 - a.0) * t).rounded(), y: (a.1 + (b.1 - a.1) * t).rounded()))
            }
        }
        if let last = points.last { out.append(GlyphPoint(x: last.0, y: last.1)) }
        return GlyphStroke(pen: .marker, weight: weight, points: out)
    }

    private var letterA: DrawnGlyph { DrawnGlyph(strokes: [line([(0, 0), (250, 700), (500, 0)]), line([(120, 250), (380, 250)])]) }
    /// A second A, wider and lower in the bar, as a hand draws it again.
    private var letterA2: DrawnGlyph { DrawnGlyph(strokes: [line([(0, 0), (300, 700), (600, 0)]), line([(140, 200), (460, 200)])]) }
    private var letterA3: DrawnGlyph { DrawnGlyph(strokes: [line([(0, 0), (200, 700), (420, 0)]), line([(90, 280), (330, 280)])]) }
    private var letterV: DrawnGlyph { DrawnGlyph(strokes: [line([(0, 700), (250, 0), (500, 700)])]) }
    private var letterH: DrawnGlyph {
        DrawnGlyph(strokes: [line([(0, 0), (0, 700)]), line([(400, 0), (400, 700)]), line([(0, 350), (400, 350)])])
    }
    private var letterI: DrawnGlyph { DrawnGlyph(strokes: [line([(0, 0), (0, 700)])]) }

    private func font(_ glyphs: [String: DrawnGlyph], alternates: [String: [DrawnGlyph]] = [:], kerning: [String: Int] = [:],
                      name: String = "Family Hand") -> DrawnFont {
        DrawnFont(name: name, glyphs: glyphs, alternates: alternates, kerning: kerning)
    }

    private func ctFont(_ data: Data?, size: CGFloat = 1000) throws -> CTFont {
        let data = try XCTUnwrap(data, "a font file")
        let descriptor = try XCTUnwrap(CTFontManagerCreateFontDescriptorFromData(data as CFData), "Core Text reads it")
        return CTFontCreateWithFontDescriptor(descriptor, size, nil)
    }

    private func glyphs(_ string: String, in font: CTFont) -> [CGGlyph] {
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: string, attributes: [
            NSAttributedString.Key(kCTFontAttributeName as String): font]))
        return (CTLineGetGlyphRuns(line) as! [CTRun]).flatMap { run -> [CGGlyph] in
            var glyphs = [CGGlyph](repeating: 0, count: CTRunGetGlyphCount(run))
            CTRunGetGlyphs(run, CFRange(location: 0, length: 0), &glyphs)
            return glyphs
        }
    }

    private func width(_ string: String, in font: CTFont) -> CGFloat {
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: string, attributes: [
            NSAttributedString.Key(kCTFontAttributeName as String): font]))
        return CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil))
    }

    // MARK: - Kerning

    /// A kerned pair is set closer by its kerning, in capitals and in the small letters that
    /// take them; a pair not kerned is not.
    func testKerningSetsAPairCloser() throws {
        let plain = try ctFont(DrawnFontFile.trueType(for: font(["A": letterA, "V": letterV])))
        let kerned = try ctFont(DrawnFontFile.trueType(for: font(["A": letterA, "V": letterV], kerning: ["AV": -120])))
        XCTAssertEqual(width("AV", in: kerned), width("AV", in: plain) - 120, accuracy: 1)
        XCTAssertEqual(width("av", in: kerned), width("AV", in: plain) - 120, accuracy: 1, "the small letters too")
        XCTAssertEqual(width("VA", in: kerned), width("VA", in: plain), accuracy: 1, "VA is another pair")
    }

    /// The outlines suggest bringing A and V together, and leave two straight letters alone.
    func testSuggestionsKernSlantedPairsAndNotStraightOnes() {
        let a = GlyphOutline.contours(of: letterA), v = GlyphOutline.contours(of: letterV), h = GlyphOutline.contours(of: letterH)
        XCTAssertLessThan(DrawnFontKerning.suggest(left: a, right: v, spacing: 50), -40)
        XCTAssertEqual(DrawnFontKerning.suggest(left: h, right: h, spacing: 50), 0)
        XCTAssertEqual(DrawnFontKerning.suggest(left: a, right: v, spacing: 50) % 5, 0, "in fives")
    }

    // MARK: - Versions

    /// A character's other versions are glyphs of their own, answering to private-use
    /// characters; repeats rotate through them, small letters with their capitals.
    func testRepeatsRotateThroughTheVersions() throws {
        let drawn = font(["A": letterA, "I": letterI], alternates: ["A": [letterA2, letterA3]])
        XCTAssertEqual(drawn.versions(of: "A"), 3)
        XCTAssertEqual(drawn.versions(of: "I"), 1)
        let ct = try ctFont(DrawnFontFile.trueType(for: drawn))
        let second = try XCTUnwrap(DrawnFont.alternateScalar(for: "A", version: 1))
        let third = try XCTUnwrap(DrawnFont.alternateScalar(for: "A", version: 2))
        let found = glyphs("A\(second)\(third)", in: ct)
        XCTAssertEqual(Set(found).count, 3, "three glyphs")
        XCTAssertFalse(found.contains(0))

        XCTAssertTrue(DrawnFonts.register(try XCTUnwrap(DrawnFontFile.trueType(for: drawn)), for: drawn.id))
        DrawnFonts.noteVersions(of: drawn)
        defer { DrawnFonts.unregister(drawn.id) }
        XCTAssertEqual(DrawnFonts.vary("AIAAA", font: drawn.id), "AI\(second)\(third)A")
        XCTAssertEqual(DrawnFonts.vary("aa", font: drawn.id), "a\(second)", "small letters rotate with their capitals")

        // A balloon of two As is as wide as the first version and the second
        let balloon = Balloon(style: .caption, center: .zero, text: "AA", wrapWidth: 5000, face: .clean, drawnFont: drawn.id,
                              fontSize: 1000)
        XCTAssertEqual(BalloonLayout(balloon).textBox.width, width("A\(second)", in: ct), accuracy: 2)
        XCTAssertNotEqual(width("A\(second)", in: ct), width("AA", in: ct), accuracy: 5)
    }

    /// An exported font swaps a repeated letter for its next version by itself, in any app
    /// that sets text with contextual alternates.
    func testAnExportedFontSwapsRepeats() throws {
        let drawn = font(["A": letterA, "V": letterV], alternates: ["A": [letterA2, letterA3]])
        let ct = try ctFont(DrawnFontFile.trueType(for: drawn, forExport: true))
        let second = try XCTUnwrap(DrawnFont.alternateScalar(for: "A", version: 1))
        let third = try XCTUnwrap(DrawnFont.alternateScalar(for: "A", version: 2))
        let alternates = glyphs("A\(second)\(third)", in: ct)
        let repeated = glyphs("AAAA", in: ct)
        XCTAssertEqual(repeated, [alternates[0], alternates[1], alternates[2], alternates[0]], "round the versions")
        XCTAssertEqual(glyphs("AVA", in: ct).first, glyphs("AVA", in: ct).last, "only repeats")
    }

    /// Versions come and go as they are drawn: a third needs a second, and clearing the first
    /// keeps the character drawn.
    func testVersionsAreSetAndTakenAway() {
        var drawn = font(["A": letterA])
        drawn.setGlyph(letterA3, for: "A", version: 2)
        XCTAssertEqual(drawn.versions(of: "A"), 1, "a third with no second is not counted")
        drawn.setGlyph(letterA2, for: "A", version: 1)
        XCTAssertEqual(drawn.versions(of: "A"), 3)
        drawn.setGlyph(nil, for: "A", version: 2)
        XCTAssertEqual(drawn.versions(of: "A"), 2)
        drawn.setGlyph(nil, for: "A", version: 1)
        XCTAssertNil(drawn.alternates["A"])
    }

    // MARK: - The family

    /// The four members: the bold traced with a heavier pen, the italic slanted, each named
    /// and marked as its style, the family one name.
    func testTheFamilyIsDrawnHeavierAndSlanted() throws {
        let drawn = font(["I": letterI, "H": letterH], name: "Family Hand")
        var inks: [DrawnFontStyle: CGRect] = [:]
        for style in DrawnFontStyle.allCases {
            let ct = try ctFont(DrawnFontFile.trueType(for: drawn, style: style, forExport: true))
            XCTAssertEqual(CTFontCopyFamilyName(ct) as String, "Family Hand")
            XCTAssertEqual(CTFontCopyPostScriptName(ct) as String, "FamilyHand-\(style.subfamily.replacingOccurrences(of: " ", with: ""))")
            let traits = CTFontGetSymbolicTraits(ct)
            XCTAssertEqual(traits.contains(.traitBold), style.isBold, style.rawValue)
            XCTAssertEqual(traits.contains(.traitItalic), style.isItalic, style.rawValue)
            let glyph = glyphs("I", in: ct)[0]
            inks[style] = try XCTUnwrap(CTFontCreatePathForGlyph(ct, glyph, nil)).boundingBoxOfPath
        }
        let regular = try XCTUnwrap(inks[.regular]), bold = try XCTUnwrap(inks[.bold]), italic = try XCTUnwrap(inks[.italic])
        XCTAssertEqual(bold.width, regular.width * 1.5, accuracy: 4, "a pen half as heavy again")
        XCTAssertEqual(italic.width - regular.width, 700 * tan(12 * .pi / 180), accuracy: 6, "the stroke leans right by its height")
    }

    /// The library compiles and registers the whole family, and exports it named for itself.
    func testTheLibraryKeepsTheFamily() throws {
        var drawn = library.newFont(named: "Kept Hand")
        drawn.glyphs["I"] = letterI
        library.update(drawn)
        library.waitUntilCompiled()
        for style in DrawnFontStyle.allCases { XCTAssertTrue(DrawnFonts.isRegistered(drawn.id, style: style), style.rawValue) }
        let family = library.exportedFamily(for: drawn.id)
        XCTAssertEqual(family.map(\.name), ["Kept Hand.ttf", "Kept Hand Bold.ttf", "Kept Hand Italic.ttf", "Kept Hand Bold Italic.ttf"])
    }

    // MARK: - Balloons

    /// Stressed words come out of their asterisks; a lone asterisk stays.
    func testWordsBetweenAsterisksAreStressed() {
        let runs = Balloon.stressRuns(in: "I *REALLY* MEAN IT")
        XCTAssertEqual(runs.map(\.text), ["I ", "REALLY", " MEAN IT"])
        XCTAssertEqual(runs.map(\.stressed), [false, true, false])
        XCTAssertEqual(Balloon.stressRuns(in: "*SEE ISSUE 3").map(\.text), ["*SEE ISSUE 3"])
        XCTAssertEqual(Balloon.stressRuns(in: "**").count, 0)
    }

    /// A balloon in bold is set in the font's bold, a stressed word in its bold italic; a face
    /// without an italic leans, and a face is drawn heavier for bold.
    func testABalloonIsSetInBoldItalicAndStress() throws {
        let drawn = font(["I": letterI, "H": letterH])
        for style in DrawnFontStyle.allCases {
            XCTAssertTrue(DrawnFonts.register(try XCTUnwrap(DrawnFontFile.trueType(for: drawn, style: style)), for: drawn.id, style: style))
        }
        defer { DrawnFonts.unregister(drawn.id) }
        func balloon(_ text: String, bold: Bool = false) -> Balloon {
            Balloon(style: .caption, center: .zero, text: text, wrapWidth: 9000, face: .clean, drawnFont: drawn.id, fontSize: 100,
                    bold: bold)
        }
        let regular = BalloonLayout(balloon("HIH")).textBox.width
        XCTAssertGreaterThan(BalloonLayout(balloon("HIH", bold: true)).textBox.width, regular + 3, "bold is heavier")
        XCTAssertGreaterThan(BalloonLayout(balloon("H*I*H")).textBox.width, regular + 1, "the stressed I is bold italic")

        let face = Balloon(style: .speech, center: .zero, text: "HI", wrapWidth: 400, face: .dialogue, fontSize: 30, italic: true)
        let (leaning, heavier) = LetteringType.font(for: face, size: 30, style: .italic)
        XCTAssertFalse(heavier)
        XCTAssertTrue(CTFontGetMatrix(leaning).c > 0.1 || CTFontGetSymbolicTraits(leaning).contains(.traitItalic), "it leans")
        XCTAssertTrue(LetteringType.font(for: face, size: 30, style: .bold).heavier, "the faces are bold cuts: drawn heavier")
    }

    /// Bold and italic are saved; balloons from before them read as neither.
    func testABalloonKeepsBoldAndItalic() throws {
        var balloon = Balloon(style: .speech, center: .zero, text: "Hi", wrapWidth: 100, face: .dialogue, fontSize: 20)
        balloon.bold = true
        let data = try JSONEncoder().encode(balloon)
        let back = try JSONDecoder().decode(Balloon.self, from: data)
        XCTAssertTrue(back.bold)
        XCTAssertFalse(back.italic)
        var old = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        old["bold"] = nil
        XCTAssertFalse(try JSONDecoder().decode(Balloon.self, from: JSONSerialization.data(withJSONObject: old)).bold)
    }

    /// A font saved before versions, kerning and the family reads with none and the defaults.
    func testAFontFromBeforeReads() throws {
        let old = """
        {"id":"\(UUID().uuidString)","name":"Old Hand","glyphs":{},"spacing":40,"modified":0}
        """
        let before = try JSONDecoder().decode(DrawnFont.self, from: Data(old.utf8))
        XCTAssertEqual(before.spacing, 40)
        XCTAssertTrue(before.alternates.isEmpty)
        XCTAssertTrue(before.kerning.isEmpty)
        XCTAssertEqual(before.boldness, DrawnFont.defaultBoldness)
        XCTAssertTrue(before.isDrawn)
        let round = font(["A": letterA], alternates: ["A": [letterA2]], kerning: ["AV": -40])
        XCTAssertEqual(try JSONDecoder().decode(DrawnFont.self, from: JSONEncoder().encode(round)), round)
    }

    // MARK: - Importing

    /// A font Artsy exported comes back as drawn: its letters, versions and kerning, to be
    /// drawn on again; brought in twice it is not doubled, and changed since, it comes as a copy.
    func testAnExportedFontImportsAsDrawn() throws {
        let drawn = font(["A": letterA, "V": letterV], alternates: ["A": [letterA2]], kerning: ["AV": -60], name: "Round Trip")
        let file = try XCTUnwrap(DrawnFontFile.trueType(for: drawn, forExport: true))
        let imported = try library.importFont(file)
        XCTAssertEqual(imported.id, drawn.id, "the same font, so documents set in it find it")
        XCTAssertTrue(imported.isDrawn)
        XCTAssertEqual(imported.glyphs, drawn.glyphs)
        XCTAssertEqual(imported.alternates, drawn.alternates)
        XCTAssertEqual(imported.kerning, drawn.kerning)
        XCTAssertEqual(try library.importFont(file).id, drawn.id)
        XCTAssertEqual(library.fonts.count, 1)

        var changed = imported
        changed.glyphs["V"] = nil
        library.update(changed)
        let copy = try library.importFont(file)
        XCTAssertNotEqual(copy.id, drawn.id)
        XCTAssertEqual(library.fonts.count, 2)
    }

    /// Any other font is set as it is, named for its family; one whose maker forbids embedding
    /// stays out of documents; a collection or a file that is not a font is turned away.
    func testAnyOtherFontImportsAsItIs() throws {
        let foreign = try XCTUnwrap(DrawnFontFile.trueType(for: font(["H": letterH], name: "Shop Font")))
        let imported = try library.importFont(foreign)
        XCTAssertFalse(imported.isDrawn)
        XCTAssertEqual(imported.name, "Shop Font")
        XCTAssertEqual(imported.imported?.embeddable, true)
        library.waitUntilCompiled()
        XCTAssertTrue(DrawnFonts.isRegistered(imported.id))
        XCTAssertNil(library.exportedFile(for: imported.id), "an imported font is not exported again")

        // Its maker's fsType says restricted
        var bytes = [UInt8](foreign)
        let os2 = try XCTUnwrap(DrawnFontFile.tableDirectory(bytes)["OS/2"])
        bytes[os2.lowerBound + 8] = 0; bytes[os2.lowerBound + 9] = 0x02
        let restricted = try library.importFont(Data(bytes))
        XCTAssertEqual(restricted.imported?.embeddable, false)
        XCTAssertEqual(restricted.name, "Shop Font 2")

        let harness = try EngineHarness(width: 300, height: 200)
        harness.viewModel.balloonDrawnFont = restricted.id
        harness.viewModel.letteringDown(at: CGPoint(x: 150, y: 100), renderer: harness.renderer)
        XCTAssertNil(CanvasDocument.drawnFonts(of: harness.layerStack), "it does not travel")
        harness.viewModel.balloonDrawnFont = imported.id
        harness.viewModel.letteringDown(at: CGPoint(x: 20, y: 20), renderer: harness.renderer)
        harness.viewModel.letteringDown(at: CGPoint(x: 40, y: 40), renderer: harness.renderer)
        XCTAssertEqual(CanvasDocument.drawnFonts(of: harness.layerStack)?.map(\.id), [imported.id])

        XCTAssertThrowsError(try library.importFont(Data("ttcf and more".utf8)))
        XCTAssertThrowsError(try library.importFont(Data("not a font at all".utf8)))
    }

    #if canImport(Artsy)
    // MARK: - The studio

    /// The studio draws a second version over the first, clears the first to let the second
    /// take its place, and kerns a pair as one step however far it is dragged.
    func testTheStudioDrawsVersionsAndKerns() throws {
        let model = FontStudioModel(library: library)
        model.newFont()
        let id = try XCTUnwrap(model.fontID)
        XCTAssertEqual(model.versionsOffered, 1, "a second version needs a first")
        model.add(line([(0, 0), (250, 700), (500, 0)]))
        XCTAssertEqual(model.versionsOffered, 2)
        model.version = 1
        XCTAssertNotNil(model.guide, "the first behind the second")
        model.add(line([(0, 0), (300, 700), (600, 0)]))
        XCTAssertEqual(library.font(id: id)?.versions(of: "A"), 2)
        model.version = 0
        model.clear()
        XCTAssertEqual(library.font(id: id)?.versions(of: "A"), 1, "the second took the first's place")
        XCTAssertEqual(library.font(id: id)?.glyph(for: "A")?.strokes.first?.points.last?.x, 600)
        model.undo()
        XCTAssertEqual(library.font(id: id)?.versions(of: "A"), 2)

        model.character = "V"
        model.add(line([(0, 700), (250, 0), (500, 700)]))
        model.mode = .kerning
        model.pair = "AV"
        model.setKerning(-20)
        model.setKerning(-40)
        model.setKerning(-60)
        XCTAssertEqual(library.font(id: id)?.kerning("A", "V"), -60)
        model.undo()
        XCTAssertEqual(library.font(id: id)?.kerning("A", "V"), 0, "a drag is one step")
        model.kernUsualPairs()
        XCTAssertLessThan(library.font(id: id)?.kerning("A", "V") ?? 0, 0, "suggested")
        XCTAssertTrue(model.kerningPairs.contains("AV"))
    }
    #endif
}
