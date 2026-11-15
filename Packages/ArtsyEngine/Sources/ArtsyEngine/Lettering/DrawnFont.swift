import CoreGraphics
import Foundation

/// A lettering font drawn by hand in the Font Studio: a glyph for each character drawn, each
/// a few pen strokes on the sheet's guides, in font units (an em of 1,000, y up, the baseline
/// at 0). A character can be drawn in up to three versions, which repeats rotate through, as
/// hand lettering never makes a letter twice the same; pairs of letters can be kerned; and
/// the font is a family, its bold drawn with a heavier pen and its italic slanted. A font
/// file made elsewhere can be imported as it is (`imported`), set but not drawn on. Set in
/// balloons through `DrawnFonts`, saved by `DrawnFontLibrary`, written as TrueType by
/// `DrawnFontFile`.
public struct DrawnFont: Codable, Equatable, Identifiable {
    public var id: UUID
    public var name: String
    /// The glyphs drawn, by their character: each character's first version.
    public var glyphs: [String: DrawnGlyph]
    /// Each character's other versions, second and third, by their character.
    public var alternates: [String: [DrawnGlyph]]
    /// The room either side of every letter's ink, in font units.
    public var spacing: Int
    /// Pairs of characters set closer (negative) or further apart, in font units, by the two
    /// characters as a string ("AV").
    public var kerning: [String: Int]
    /// How much heavier the bold's pen is than the drawing's.
    public var boldness: CGFloat
    /// How far the italic leans, in degrees.
    public var slant: CGFloat
    /// A font file imported as it is, set from its own outlines; nil for a font drawn here.
    public var imported: ImportedFont?
    public var modified: Date

    public init(id: UUID = UUID(), name: String, glyphs: [String: DrawnGlyph] = [:], alternates: [String: [DrawnGlyph]] = [:],
                spacing: Int = DrawnFont.defaultSpacing, kerning: [String: Int] = [:],
                boldness: CGFloat = DrawnFont.defaultBoldness, slant: CGFloat = DrawnFont.defaultSlant,
                imported: ImportedFont? = nil, modified: Date = Date()) {
        self.id = id
        self.name = name
        self.glyphs = glyphs
        self.alternates = alternates
        self.spacing = spacing
        self.kerning = kerning
        self.boldness = boldness
        self.slant = slant
        self.imported = imported
        self.modified = modified
    }

    // Fonts saved before versions, kerning and the family read with none and the defaults
    private enum CodingKeys: String, CodingKey {
        case id, name, glyphs, alternates, spacing, kerning, boldness, slant, imported, modified
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        glyphs = try c.decodeIfPresent([String: DrawnGlyph].self, forKey: .glyphs) ?? [:]
        alternates = try c.decodeIfPresent([String: [DrawnGlyph]].self, forKey: .alternates) ?? [:]
        spacing = try c.decodeIfPresent(Int.self, forKey: .spacing) ?? Self.defaultSpacing
        kerning = try c.decodeIfPresent([String: Int].self, forKey: .kerning) ?? [:]
        boldness = try c.decodeIfPresent(CGFloat.self, forKey: .boldness) ?? Self.defaultBoldness
        slant = try c.decodeIfPresent(CGFloat.self, forKey: .slant) ?? Self.defaultSlant
        imported = try c.decodeIfPresent(ImportedFont.self, forKey: .imported)
        modified = try c.decodeIfPresent(Date.self, forKey: .modified) ?? Date()
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(name, forKey: .name)
        try c.encode(glyphs, forKey: .glyphs)
        if !alternates.isEmpty { try c.encode(alternates, forKey: .alternates) }
        try c.encode(spacing, forKey: .spacing)
        if !kerning.isEmpty { try c.encode(kerning, forKey: .kerning) }
        try c.encode(boldness, forKey: .boldness)
        try c.encode(slant, forKey: .slant)
        try c.encodeIfPresent(imported, forKey: .imported)
        try c.encode(modified, forKey: .modified)
    }

    /// Whether the font was drawn here, so its letters can be drawn on.
    public var isDrawn: Bool { imported == nil }

    public static let defaultBoldness: CGFloat = 1.5
    public static let boldnessRange: ClosedRange<CGFloat> = 1.15...2.2
    public static let defaultSlant: CGFloat = 12
    public static let slantRange: ClosedRange<CGFloat> = 0...22

    // MARK: - Versions

    /// The most versions a character can be drawn in.
    public static let maxVersions = 3

    /// The character's `version`th glyph (0 the first), if drawn.
    public func glyph(for character: Character, version: Int) -> DrawnGlyph? {
        if version == 0 { return glyph(for: character) }
        guard let others = alternates[String(character)], others.indices.contains(version - 1),
              !others[version - 1].strokes.isEmpty else { return nil }
        return others[version - 1]
    }

    /// How many versions of the character are drawn: its first and the others after it.
    public func versions(of character: Character) -> Int {
        guard glyph(for: character) != nil else { return 0 }
        var count = 1
        while count < Self.maxVersions, glyph(for: character, version: count) != nil { count += 1 }
        return count
    }

    /// Sets the character's `version`th glyph, nil or empty taking it away.
    public mutating func setGlyph(_ glyph: DrawnGlyph?, for character: Character, version: Int) {
        let key = String(character)
        let kept = glyph?.strokes.isEmpty == false ? glyph : nil
        if version == 0 {
            glyphs[key] = kept
            return
        }
        var others = alternates[key] ?? []
        while others.count < version { others.append(DrawnGlyph()) }
        others[version - 1] = kept ?? DrawnGlyph()
        while let last = others.last, last.strokes.isEmpty { others.removeLast() }
        alternates[key] = others.isEmpty ? nil : others
    }

    // MARK: - Kerning

    /// The kerning of `left` followed by `right`, in font units.
    public func kerning(_ left: Character, _ right: Character) -> Int {
        kerning[String([left, right])] ?? 0
    }

    public mutating func setKerning(_ value: Int, _ left: Character, _ right: Character) {
        kerning[String([left, right])] = value == 0 ? nil : value
    }

    public static let defaultSpacing = 50
    public static let spacingRange = 0...200

    // MARK: - The guides

    public static let unitsPerEm = 1000
    /// Where the guides are, in font units above the baseline.
    public static let capHeight: CGFloat = 700, xHeight: CGFloat = 500, descender: CGFloat = -220
    /// What the drawing sheet shows, in font units: a square from below the descender to
    /// above the capitals, with room either side for a wide letter.
    public static let sheet = CGRect(x: -100, y: -330, width: 1200, height: 1200)

    // MARK: - The characters

    public static let capitals = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZ")
    public static let figures = Array("0123456789")
    public static let punctuation = Array(".,!?'\"-—…:;()&*/@#$%+=♥♪")
    public static let smallLetters = Array("abcdefghijklmnopqrstuvwxyz")
    /// Every character a font can have, in the order they are drawn: capitals first, as
    /// comics are lettered, then figures, punctuation and small letters.
    public static let characters: [Character] = capitals + figures + punctuation + smallLetters
    /// Characters set in another's glyph when they have none of their own.
    public static let alternates: [Character: Character] = ["’": "'", "‘": "'", "“": "\"", "”": "\"", "–": "-"]

    /// The glyph drawn for `character`, if it has ink.
    public func glyph(for character: Character) -> DrawnGlyph? {
        guard let glyph = glyphs[String(character)], !glyph.strokes.isEmpty else { return nil }
        return glyph
    }

    /// The characters drawn so far.
    public var drawn: Set<Character> {
        Set(glyphs.compactMap { $0.value.strokes.isEmpty ? nil : Character($0.key) })
    }

    /// The character a font sets for `character`: itself if drawn, else its other case if
    /// that is drawn (a capital answers for its small letter and back), else itself.
    public func setting(_ character: Character) -> Character {
        if glyph(for: character) != nil { return character }
        let other = Character(character.isUppercase ? character.lowercased() : character.uppercased())
        if other != character, other.isLetter, glyph(for: other) != nil { return other }
        return character
    }

    /// The private-use character a font answers to with `character`'s `version`th glyph
    /// (1 or 2), for setting a repeat in another version: U+E000 on, four to a character.
    public static func alternateScalar(for character: Character, version: Int) -> Unicode.Scalar? {
        guard version > 0, version < maxVersions, let index = characters.firstIndex(of: character) else { return nil }
        return Unicode.Scalar(0xE000 + index * 4 + version)
    }

    /// A name for a new font not yet taken by any of `fonts`: "My Lettering", then "My Lettering 2"…
    public static func newName(among fonts: [DrawnFont], base: String = "My Lettering") -> String {
        let taken = Set(fonts.map(\.name))
        if !taken.contains(base) { return base }
        var n = 2
        while taken.contains("\(base) \(n)") { n += 1 }
        return "\(base) \(n)"
    }
}

/// A character's strokes, drawn bottom first.
public struct DrawnGlyph: Codable, Equatable {
    public var strokes: [GlyphStroke]

    public init(strokes: [GlyphStroke] = []) {
        self.strokes = strokes
    }

    /// The glyph drawn with every pen `factor` times as heavy: the bold's.
    public func emboldened(by factor: CGFloat) -> DrawnGlyph {
        DrawnGlyph(strokes: strokes.map { GlyphStroke(pen: $0.pen, weight: $0.weight * factor, points: $0.points) })
    }
}

/// A font file brought in as it is (TrueType or OpenType): set from its own outlines, its
/// letters not drawn on. Whether its maker allows it to travel inside documents is read from
/// it (OS/2's embedding bits): a font that may not goes with no document.
public struct ImportedFont: Codable, Equatable {
    public var data: Data
    public var embeddable: Bool

    public init(data: Data, embeddable: Bool) {
        self.data = data
        self.embeddable = embeddable
    }
}

/// The four members of a font's family.
public enum DrawnFontStyle: String, CaseIterable, Identifiable, Codable {
    case regular, bold, italic, boldItalic

    public var id: String { rawValue }
    public var isBold: Bool { self == .bold || self == .boldItalic }
    public var isItalic: Bool { self == .italic || self == .boldItalic }

    public init(bold: Bool, italic: Bool) {
        switch (bold, italic) {
        case (false, false): self = .regular
        case (true, false): self = .bold
        case (false, true): self = .italic
        case (true, true): self = .boldItalic
        }
    }

    /// The name a font file gives it.
    public var subfamily: String {
        switch self {
        case .regular: return "Regular"
        case .bold: return "Bold"
        case .italic: return "Italic"
        case .boldItalic: return "Bold Italic"
        }
    }
}

/// What a glyph's stroke was drawn with: a round marker of one width, a round brush wider
/// with pressure, or a broad chisel nib held at an angle.
public enum GlyphPen: String, Codable, CaseIterable, Identifiable {
    case marker, brush, chisel

    public var id: String { rawValue }

    /// A round pen's width at a point pressed `pressure` (0...1) with weight `weight`; for
    /// the chisel, the nib's length.
    public func width(weight: CGFloat, pressure: CGFloat) -> CGFloat {
        switch self {
        case .marker, .chisel: return weight
        case .brush: return weight * (0.3 + 0.7 * min(max(pressure, 0), 1))
        }
    }

    /// The chisel's nib: its angle, and its thickness as a share of its length.
    public static let nibAngle: CGFloat = .pi * 35 / 180, nibThickness: CGFloat = 0.14

    public static let weightRange: ClosedRange<CGFloat> = 20...220
    public static let defaultWeight: CGFloat = 80
}

/// One stroke of a glyph: the pen, its weight (its width at full pressure, in font units)
/// and the points it went through.
public struct GlyphStroke: Codable, Equatable {
    public var pen: GlyphPen
    public var weight: CGFloat
    public var points: [GlyphPoint]

    public init(pen: GlyphPen, weight: CGFloat, points: [GlyphPoint]) {
        self.pen = pen
        self.weight = weight
        self.points = points
    }

    /// The width at each point.
    public func width(at index: Int) -> CGFloat {
        pen.width(weight: weight, pressure: points[index].pressure)
    }

    // Points as one row of numbers, x, y and pressure for each, to a tenth of a unit
    private enum CodingKeys: String, CodingKey { case pen, weight, points }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        pen = try c.decode(GlyphPen.self, forKey: .pen)
        weight = try c.decode(CGFloat.self, forKey: .weight)
        let numbers = try c.decode([Double].self, forKey: .points)
        points = stride(from: 0, to: numbers.count - 2, by: 3).map {
            GlyphPoint(x: numbers[$0], y: numbers[$0 + 1], pressure: numbers[$0 + 2])
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(pen, forKey: .pen)
        try c.encode((weight * 10).rounded() / 10, forKey: .weight)
        func tenth(_ v: CGFloat) -> Double { Double((v * 10).rounded() / 10) }
        func hundredth(_ v: CGFloat) -> Double { Double((v * 100).rounded() / 100) }
        try c.encode(points.flatMap { [tenth($0.x), tenth($0.y), hundredth($0.pressure)] }, forKey: .points)
    }

    // MARK: - Smoothing

    /// The stroke as it settles when the pen lifts: its points spaced evenly, `spacing`
    /// font units apart, and their wobble eased out (a few passes of each point toward the
    /// middle of its neighbours), the ends where they were. A pen's tremor and a mouse's
    /// steps go; the shape stays.
    public func smoothed(spacing: CGFloat = 6, passes: Int = 3) -> GlyphStroke {
        guard points.count > 2 else { return self }
        // Evenly spaced along the way the pen went
        var even: [GlyphPoint] = [points[0]]
        var carried: CGFloat = 0
        for i in 1..<points.count {
            let a = points[i - 1], b = points[i]
            let length = hypot(b.x - a.x, b.y - a.y)
            guard length > 0 else { continue }
            var at = spacing - carried
            while at <= length {
                let t = at / length
                even.append(GlyphPoint(x: a.x + (b.x - a.x) * t, y: a.y + (b.y - a.y) * t,
                                       pressure: a.pressure + (b.pressure - a.pressure) * t))
                at += spacing
            }
            carried = length - (at - spacing)
        }
        if let last = points.last, let end = even.last, hypot(last.x - end.x, last.y - end.y) > spacing * 0.25 {
            even.append(last)
        }
        guard even.count > 2 else { return GlyphStroke(pen: pen, weight: weight, points: even) }
        for _ in 0..<passes {
            var next = even
            for i in 1..<(even.count - 1) {
                let a = even[i - 1], b = even[i], c = even[i + 1]
                next[i] = GlyphPoint(x: (a.x + 2 * b.x + c.x) / 4, y: (a.y + 2 * b.y + c.y) / 4,
                                     pressure: (a.pressure + 2 * b.pressure + c.pressure) / 4)
            }
            even = next
        }
        return GlyphStroke(pen: pen, weight: weight, points: even)
    }
}

/// A point a glyph's stroke went through, in font units, and how hard the pen pressed (0...1;
/// a mouse presses fully).
public struct GlyphPoint: Equatable {
    public var x: CGFloat
    public var y: CGFloat
    public var pressure: CGFloat

    public init(x: CGFloat, y: CGFloat, pressure: CGFloat = 1) {
        self.x = x
        self.y = y
        self.pressure = pressure
    }
}
