import SwiftUI
import ArtsyEngine

/// What the Font Studio shows of the font open: its letters to draw, its kerning, or its
/// family (bold and italic).
enum FontStudioMode: String, CaseIterable, Identifiable {
    case letters, kerning, family
    var id: String { rawValue }
}

/// The Font Studio's state: the font open, the character and version being drawn, the pen,
/// the pair being kerned, and the changes made and taken back since it opened. Every change
/// goes to the library at once, which saves and compiles it, so balloons set in the font
/// follow as it is drawn.
final class FontStudioModel: ObservableObject {
    let library: DrawnFontLibrary
    @Published var fontID: UUID? {
        didSet { if fontID != oldValue { version = 0 } }
    }
    @Published var mode: FontStudioMode = .letters
    @Published var character: Character = "A" {
        didSet { if character != oldValue { version = 0 } }
    }
    /// Which version of the character is drawn on: 0 its first.
    @Published var version = 0
    @Published var pair = "AV"
    @Published var pen: GlyphPen {
        didSet { UserDefaults.standard.set(pen.rawValue, forKey: Self.penKey) }
    }
    @Published var weight: CGFloat {
        didSet { UserDefaults.standard.set(Double(weight), forKey: Self.weightKey) }
    }
    @Published private(set) var canUndo = false
    @Published private(set) var canRedo = false

    private static let penKey = "fontStudio.pen", weightKey = "fontStudio.weight"

    /// A change to a font, undone by putting `before` back, with where it was made to return
    /// to. A run of changes of one `kind` (a kerning dragged) is one step.
    private struct Step {
        let kind: String
        let before: DrawnFont
        var after: DrawnFont
        let mode: FontStudioMode
        let character: Character
        let version: Int
        let pair: String
    }
    private var undoStack: [Step] = [] { didSet { canUndo = !undoStack.isEmpty } }
    private var redoStack: [Step] = [] { didSet { canRedo = !redoStack.isEmpty } }

    init(library: DrawnFontLibrary = .shared, font: UUID? = nil) {
        self.library = library
        fontID = font.flatMap { library.font(id: $0)?.id } ?? library.fonts.first?.id
        pen = UserDefaults.standard.string(forKey: Self.penKey).flatMap(GlyphPen.init(rawValue:)) ?? .marker
        let saved = UserDefaults.standard.double(forKey: Self.weightKey)
        weight = saved > 0 ? CGFloat(saved) : GlyphPen.defaultWeight
    }

    var font: DrawnFont? { library.font(id: fontID) }
    /// The glyph drawn on: the character's version in hand, if drawn.
    var glyph: DrawnGlyph? { font?.glyph(for: character, version: version) }
    /// What the pad shows faintly behind a second or third version: the first.
    var guide: DrawnGlyph? { version > 0 ? font?.glyph(for: character) : nil }
    /// How many versions can be chosen: those drawn, and one more to draw.
    var versionsOffered: Int {
        guard let font else { return 1 }
        return min(DrawnFont.maxVersions, font.versions(of: character) + 1)
    }

    // MARK: - Changing the font

    private func change(_ kind: String, _ edit: (inout DrawnFont) -> Void) {
        guard var font, font.isDrawn else { return }
        let before = font
        edit(&font)
        guard font != before else { return }
        if let last = undoStack.last, last.kind == kind, last.after.id == font.id, last.after == before, kind.hasPrefix("kern") {
            undoStack[undoStack.count - 1].after = font
        } else {
            undoStack.append(Step(kind: kind, before: before, after: font, mode: mode, character: character, version: version, pair: pair))
            if undoStack.count > 200 { undoStack.removeFirst() }
        }
        redoStack.removeAll()
        library.update(font)
        // The step ends with the font as the library keeps it, stamped with when it changed,
        // so the next change in a run starts from what the step ended with and joins it
        if let kept = library.font(id: font.id), !undoStack.isEmpty { undoStack[undoStack.count - 1].after = kept }
        objectWillChange.send()
    }

    /// The last change taken back, the font, mode and character it was made in brought up.
    func undo() {
        guard let step = undoStack.popLast() else { return }
        guard library.font(id: step.before.id) != nil else { return undo() }
        redoStack.append(step)
        restore(step, to: step.before)
    }

    func redo() {
        guard let step = redoStack.popLast() else { return }
        guard library.font(id: step.after.id) != nil else { return redo() }
        undoStack.append(step)
        restore(step, to: step.after)
    }

    private func restore(_ step: Step, to font: DrawnFont) {
        fontID = font.id
        mode = step.mode
        character = step.character
        version = min(step.version, max(0, font.versions(of: step.character)))
        pair = step.pair
        library.update(font)
        objectWillChange.send()
    }

    // MARK: - Drawing

    /// A stroke drawn on the character's version in hand.
    func add(_ stroke: GlyphStroke) {
        guard !stroke.points.isEmpty else { return }
        let character = self.character, version = self.version
        change("draw") { font in
            var glyph = font.glyph(for: character, version: version) ?? DrawnGlyph()
            glyph.strokes.append(stroke)
            font.setGlyph(glyph, for: character, version: version)
        }
    }

    /// The version in hand drawn again from nothing; the first cleared with others drawn,
    /// the second becomes the first.
    func clear() {
        guard glyph != nil else { return }
        let character = self.character, version = self.version
        change("clear") { font in
            let count = font.versions(of: character)
            var versions = (0..<count).compactMap { font.glyph(for: character, version: $0) }
            versions.remove(at: min(version, versions.count - 1))
            for v in 0..<DrawnFont.maxVersions { font.setGlyph(v < versions.count ? versions[v] : nil, for: character, version: v) }
        }
        self.version = min(version, max(0, (font?.versions(of: character) ?? 1) - 1))
    }

    // MARK: - Characters

    func select(_ character: Character) {
        let found = DrawnFont.characters.contains(character) ? character
            : DrawnFont.alternates[character] ?? character
        guard DrawnFont.characters.contains(found) else { return }
        self.character = found
    }

    /// The character `offset` along from this one, round the end.
    func step(by offset: Int) {
        let all = DrawnFont.characters
        let index = all.firstIndex(of: character) ?? 0
        character = all[(index + offset + all.count) % all.count]
    }

    // MARK: - Kerning

    /// The pairs to kern: those kerned already, then the usual pairs whose letters are drawn.
    var kerningPairs: [String] {
        guard let font else { return [] }
        func drawn(_ pair: String) -> Bool {
            let c = Array(pair)
            return c.count == 2 && font.glyph(for: font.setting(c[0])) != nil && font.glyph(for: font.setting(c[1])) != nil
        }
        let kerned = font.kerning.keys.sorted()
        let usual = DrawnFontKerning.commonPairs.filter { drawn($0) && font.kerning[$0] == nil }
        return kerned + usual
    }

    /// The pair in hand's kerning.
    var kerning: Int {
        let c = Array(pair)
        guard c.count == 2, let font else { return 0 }
        return font.kerning(c[0], c[1])
    }

    func setKerning(_ value: Int) {
        let c = Array(pair)
        guard c.count == 2 else { return }
        change("kern \(pair)") { $0.setKerning(value, c[0], c[1]) }
    }

    /// The kerning the pair's outlines suggest.
    func suggestedKerning(for pair: String) -> Int? {
        let c = Array(pair)
        guard c.count == 2, let font, let left = font.glyph(for: font.setting(c[0])),
              let right = font.glyph(for: font.setting(c[1])) else { return nil }
        return DrawnFontKerning.suggest(left: GlyphOutline.contours(of: left), right: GlyphOutline.contours(of: right),
                                        spacing: font.spacing)
    }

    /// Every usual pair whose letters are drawn and not kerned yet, kerned as suggested
    /// where the suggestion is worth having; one step.
    func kernUsualPairs() {
        guard let font else { return }
        var outlines: [Character: [GlyphOutline.Contour]] = [:]
        func contours(_ c: Character) -> [GlyphOutline.Contour]? {
            let set = font.setting(c)
            if let known = outlines[set] { return known }
            guard let glyph = font.glyph(for: set) else { return nil }
            let traced = GlyphOutline.contours(of: glyph)
            outlines[set] = traced
            return traced
        }
        var suggestions: [(Character, Character, Int)] = []
        for pair in DrawnFontKerning.commonPairs where font.kerning[pair] == nil {
            let c = Array(pair)
            guard let left = contours(c[0]), let right = contours(c[1]) else { continue }
            let value = DrawnFontKerning.suggest(left: left, right: right, spacing: font.spacing)
            if abs(value) >= 10 { suggestions.append((c[0], c[1], value)) }
        }
        guard !suggestions.isEmpty else { return }
        change("kern the usual pairs") { font in
            for (l, r, value) in suggestions { font.setKerning(value, l, r) }
        }
    }

    // MARK: - Fonts

    func newFont() {
        fontID = library.newFont().id
        character = "A"
        mode = .letters
    }

    func duplicate() {
        guard let id = fontID, let copy = library.duplicate(id) else { return }
        fontID = copy.id
    }

    func deleteFont() {
        guard let id = fontID else { return }
        library.delete(id)
        undoStack.removeAll { $0.after.id == id }
        redoStack.removeAll { $0.after.id == id }
        fontID = library.fonts.first?.id
    }

    func rename(_ name: String) {
        guard var font, font.name != name else { return }
        font.name = name
        library.update(font)
    }

    func setSpacing(_ spacing: Int) {
        guard var font, font.spacing != spacing else { return }
        font.spacing = spacing
        library.update(font)
    }

    func setBoldness(_ boldness: CGFloat) {
        guard var font, font.boldness != boldness else { return }
        font.boldness = boldness
        library.update(font)
    }

    func setSlant(_ slant: CGFloat) {
        guard var font, font.slant != slant else { return }
        font.slant = slant
        library.update(font)
    }

    /// A font file brought in, and opened.
    func importFont(from url: URL) throws {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        let font = try library.importFont(try Data(contentsOf: url))
        fontID = font.id
        mode = .letters
    }

    /// The open font's regular as a TrueType file, to export.
    func exportedFile() -> FontFile? {
        guard let id = fontID, let font, let data = library.exportedFile(for: id) else { return nil }
        return FontFile(data: data, name: DrawnFontFile.familyName(of: font))
    }

    /// The open font's whole family, a folder of four files, to export.
    func exportedFamily() -> FontFamilyFolder? {
        guard let id = fontID, let font else { return nil }
        let files = library.exportedFamily(for: id)
        guard !files.isEmpty else { return nil }
        return FontFamilyFolder(files: files, name: "\(DrawnFontFile.familyName(of: font)) family")
    }
}
