import CoreGraphics
import CoreText
import Foundation

/// A drawn font as TrueType files: the bytes Core Text reads from memory to set balloons, and
/// the files the Font Studio exports for any other app. Etchy's handwriting font is the
/// pattern: glyphs of straight-sided outlines (every point on the curve), no hinting.
///
/// A letter drawn only as a capital, or only small, answers for both; curly quotes take the
/// straight ones and the en dash the hyphen. A line is 1.1 em, the capitals in its middle.
/// Each member of the family is a file of its own: the bold traced from the same strokes
/// with a heavier pen, the italic slanted. A character's other versions are glyphs of their
/// own, answering to private-use characters (`DrawnFont.alternateScalar`), which balloons
/// rotate through; an exported file also swaps them in for a letter repeated (`calt`), and
/// carries the drawing itself, so the file imported again is the font as drawn.
public enum DrawnFontFile {
    /// The lines' reach above and below the baseline.
    static let ascender = 900, descender = -200
    /// The space between words, before the letters' own spacing.
    static let wordSpace = 260

    /// A glyph a font draws: a character and which of its versions.
    public struct GlyphKey: Hashable {
        public let character: Character
        public let version: Int

        public init(_ character: Character, _ version: Int) {
            self.character = character
            self.version = version
        }
    }

    /// Clean contours by glyph, at one weight.
    public typealias Outlines = [GlyphKey: [GlyphOutline.Contour]]

    /// A glyph ready for the font: its contours set its spacing from the left.
    struct Glyph {
        var contours: [GlyphOutline.Contour]
        var advance: Int
        var bounds: (xMin: Int, yMin: Int, xMax: Int, yMax: Int)
    }

    /// One glyph of the font and what answers to it.
    struct Entry {
        var key: GlyphKey
        var codes: [UInt32]
        var glyph: Glyph
    }

    /// The `style` member of the font's family as a file, or nil if nothing is drawn.
    /// `outlines` are the clean contours of its glyphs at the style's weight (the drawing's,
    /// or the bold's), worked out by whoever keeps them; missing ones are traced here. A
    /// font for use (`forExport` false) carries a digest in its PostScript name, so Core
    /// Text's caches never take one version for another; an exported one is named for the
    /// font, has the rules that swap repeats, and carries the drawing.
    public static func trueType(for font: DrawnFont, style: DrawnFontStyle = .regular, outlines: Outlines = [:],
                                forExport: Bool = false) -> Data? {
        guard font.isDrawn else { return font.imported?.data }
        let spacing = max(0, font.spacing)
        let weight = style.isBold ? font.boldness : 1
        let shear = style.isItalic ? tan(font.slant * .pi / 180) : 0
        var entries: [Entry] = []
        for character in DrawnFont.characters {
            for version in 0..<font.versions(of: character) {
                let key = GlyphKey(character, version)
                var contours = outlines[key]
                    ?? font.glyph(for: character, version: version).map { GlyphOutline.contours(of: weight == 1 ? $0 : $0.emboldened(by: weight)) }
                    ?? []
                if shear != 0 {
                    contours = contours.map { $0.map { (x: Int((CGFloat($0.x) + CGFloat($0.y) * shear).rounded()), y: $0.y) } }
                }
                guard let glyph = glyph(contours, spacing: spacing) else { continue }
                var codes: [UInt32] = []
                if version == 0 {
                    var characters = [character]
                    // A letter's other case, if it is not drawn itself
                    if font.setting(Character(character.isUppercase ? character.lowercased() : character.uppercased())) == character,
                       character.isLetter {
                        characters.append(Character(character.isUppercase ? character.lowercased() : character.uppercased()))
                    }
                    characters += DrawnFont.alternates.filter { $0.value == character }.map(\.key)
                    codes = characters.compactMap { c in
                        guard c.unicodeScalars.count == 1, let s = c.unicodeScalars.first, s.value <= 0xFFFF else { return nil }
                        return s.value
                    }
                } else if let scalar = DrawnFont.alternateScalar(for: character, version: version) {
                    codes = [scalar.value]
                }
                entries.append(Entry(key: key, codes: codes, glyph: glyph))
            }
        }
        guard !entries.isEmpty else { return nil }

        // Glyph ids: .notdef 0, the space 1, then the entries
        var ids: [GlyphKey: Int] = [:]
        for (i, entry) in entries.enumerated() { ids[entry.key] = i + 2 }

        // Kerning between every version of each pair's two characters
        var pairs: [UInt32: Int] = [:]
        for (key, value) in font.kerning where value != 0 {
            let characters = Array(key)
            guard characters.count == 2 else { continue }
            let left = font.setting(characters[0]), right = font.setting(characters[1])
            for lv in 0..<max(1, font.versions(of: left)) {
                for rv in 0..<max(1, font.versions(of: right)) {
                    guard let l = ids[GlyphKey(left, lv)], let r = ids[GlyphKey(right, rv)] else { continue }
                    pairs[UInt32(l) << 16 | UInt32(r)] = value
                }
            }
        }

        // FNV-1a over everything that sets text differently
        var digest: UInt32 = 2_166_136_261
        func mix(_ value: Int) {
            for byte in withUnsafeBytes(of: Int32(truncatingIfNeeded: value), Array.init) { digest = (digest ^ UInt32(byte)) &* 16_777_619 }
        }
        for scalar in (font.name + style.rawValue).unicodeScalars { mix(Int(scalar.value)) }
        mix(spacing)
        for entry in entries {
            entry.codes.forEach { mix(Int($0)) }
            for contour in entry.glyph.contours { for p in contour { mix(p.x); mix(p.y) } }
        }
        for (pair, value) in pairs.sorted(by: { $0.key < $1.key }) { mix(Int(pair)); mix(value) }
        let tag = String(format: "%08X", digest)

        let family = familyName(of: font)
        let styleName = style.subfamily.replacingOccurrences(of: " ", with: "")
        let postScriptName = forExport ? "\(postScriptBase(of: family))-\(styleName)" : "ArtsyDrawn-\(tag)-\(styleName)"
        var extra: [(String, Bytes)] = []
        if forExport {
            if let gsub = alternateRules(entries: entries, ids: ids, font: font) { extra.append(("GSUB", gsub)) }
            if let drawing = drawingTable(of: font) { extra.append(("ARTS", drawing)) }
        }
        return TrueType.font(entries: entries, kerning: pairs, family: family, style: style, slant: style.isItalic ? font.slant : 0,
                             postScriptName: postScriptName, unique: "Artsy: \(family) \(style.subfamily) \(tag)",
                             spacing: spacing, extraTables: extra)
    }

    /// The name a font is known by in other apps: its own, or one for a font with none.
    public static func familyName(of font: DrawnFont) -> String {
        let trimmed = font.name.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "Drawn Lettering" : String(trimmed.prefix(60))
    }

    /// A PostScript name's letters: the family's letters and figures, no spaces.
    static func postScriptBase(of family: String) -> String {
        let kept = family.unicodeScalars.filter { $0.isASCII && ($0.properties.isAlphabetic || ("0"..."9").contains($0)) }
        let base = String(String.UnicodeScalarView(kept)).prefix(50)
        return base.isEmpty ? "DrawnLettering" : String(base)
    }

    /// A file name for the exported font's `style`.
    public static func fileName(of font: DrawnFont, style: DrawnFontStyle = .regular) -> String {
        let name = familyName(of: font).replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
        return style == .regular ? "\(name).ttf" : "\(name) \(style.subfamily).ttf"
    }

    /// A glyph of `contours`, set `spacing` from the left with as much after it; nil for none.
    static func glyph(_ contours: [GlyphOutline.Contour], spacing: Int) -> Glyph? {
        let xs = contours.flatMap { $0.map(\.x) }, ys = contours.flatMap { $0.map(\.y) }
        guard let xMin = xs.min(), let xMax = xs.max(), let yMin = ys.min(), let yMax = ys.max() else { return nil }
        let shift = spacing - xMin
        let width = xMax - xMin
        return Glyph(contours: contours.map { $0.map { (x: $0.x + shift, y: $0.y) } }, advance: width + 2 * spacing,
                     bounds: (spacing, yMin, spacing + width, yMax))
    }

    // MARK: - Importing

    public enum ImportError: LocalizedError {
        case unreadable, collection

        public var errorDescription: String? {
            switch self {
            case .unreadable: return "This isn't a font Artsy can read. Import a TrueType (.ttf) or OpenType (.otf) file."
            case .collection: return "This file holds several fonts. Import one font at a time (.ttf or .otf)."
            }
        }
    }

    /// The font in a file: the drawing itself if Artsy exported it, so it can be drawn on
    /// again; any other font as it is, its family and style its name.
    public static func importing(_ data: Data) throws -> DrawnFont {
        let bytes = [UInt8](data)
        if bytes.count >= 4, String(bytes: bytes[0..<4], encoding: .ascii) == "ttcf" { throw ImportError.collection }
        guard let descriptor = CTFontManagerCreateFontDescriptorFromData(data as CFData) else { throw ImportError.unreadable }
        let tables = tableDirectory(bytes)
        if let drawing = tables["ARTS"], let font = drawingFont(in: Array(bytes[drawing])) {
            return font
        }
        let font = CTFontCreateWithFontDescriptor(descriptor, 12, nil)
        let family = CTFontCopyFamilyName(font) as String
        let styleName = (CTFontCopyName(font, kCTFontStyleNameKey) as String?) ?? "Regular"
        let name = ["Regular", "Roman", "Book", "Normal"].contains(styleName) ? family : "\(family) \(styleName)"
        // OS/2's fsType, eight bytes in: installable (0) or editable (8) may travel in documents
        var embeddable = true
        if let os2 = tables["OS/2"], os2.count >= 10 {
            let fsType = Int(bytes[os2.lowerBound + 8]) << 8 | Int(bytes[os2.lowerBound + 9])
            embeddable = fsType & 0x000F == 0 || fsType & 0x0008 != 0
        }
        return DrawnFont(name: name, imported: ImportedFont(data: data, embeddable: embeddable))
    }

    /// Where each table of a font file is, by its tag.
    static func tableDirectory(_ bytes: [UInt8]) -> [String: Range<Int>] {
        func u16(_ i: Int) -> Int { i + 1 < bytes.count ? Int(bytes[i]) << 8 | Int(bytes[i + 1]) : 0 }
        func u32(_ i: Int) -> Int { u16(i) << 16 | u16(i + 2) }
        guard bytes.count >= 12 else { return [:] }
        var tables: [String: Range<Int>] = [:]
        for t in 0..<u16(4) {
            let record = 12 + t * 16
            guard record + 16 <= bytes.count, let tag = String(bytes: bytes[record..<(record + 4)], encoding: .ascii) else { break }
            let offset = u32(record + 8), length = u32(record + 12)
            guard offset + length <= bytes.count else { continue }
            tables[tag] = offset..<(offset + length)
        }
        return tables
    }

    /// The drawing an exported font carries: a version, then the font as JSON, compressed.
    static func drawingTable(of font: DrawnFont) -> Bytes? {
        var copy = font
        copy.imported = nil
        guard let json = try? JSONEncoder().encode(copy),
              let compressed = try? (json as NSData).compressed(using: .zlib) as Data else { return nil }
        var table = Bytes()
        table.u32(1)
        table.bytes += [UInt8](compressed)
        return table
    }

    static func drawingFont(in table: [UInt8]) -> DrawnFont? {
        guard table.count > 4, table[0..<4] == [0, 0, 0, 1],
              let json = try? (Data(table[4...]) as NSData).decompressed(using: .zlib) as Data else { return nil }
        return try? JSONDecoder().decode(DrawnFont.self, from: json)
    }

    // MARK: - Repeats

    /// GSUB with one feature, `calt`: a letter repeated is set in its next version, the
    /// third in the third, and round again. One chaining rule per letter and version, each
    /// handing the letter to a single substitution: its first version to its second, or to
    /// its third. Nil for a font with no other versions.
    static func alternateRules(entries: [Entry], ids: [GlyphKey: Int], font: DrawnFont) -> Bytes? {
        let varied = DrawnFont.characters.filter { font.versions(of: $0) > 1 && ids[GlyphKey($0, 0)] != nil }
        guard !varied.isEmpty else { return nil }

        func coverage(_ glyphs: [Int]) -> Bytes {
            var c = Bytes()
            c.u16(1); c.u16(UInt16(glyphs.count))
            for g in glyphs { c.u16(UInt16(g)) }
            return c
        }
        // Lookup 1: first versions to second; lookup 2: first to third
        func single(_ to: Int) -> Bytes? {
            let pairs = varied.compactMap { c -> (Int, Int)? in
                guard let from = ids[GlyphKey(c, 0)], let alt = ids[GlyphKey(c, to)] else { return nil }
                return (from, alt)
            }.sorted { $0.0 < $1.0 }
            guard !pairs.isEmpty else { return nil }
            var sub = Bytes()
            sub.u16(2)
            sub.u16(UInt16(6 + 2 * pairs.count)) // coverage after the substitutes
            sub.u16(UInt16(pairs.count))
            for p in pairs { sub.u16(UInt16(p.1)) }
            sub.bytes += coverage(pairs.map(\.0)).bytes
            return lookup(type: 1, subtables: [sub])
        }
        func lookup(type: Int, subtables: [Bytes]) -> Bytes {
            var l = Bytes()
            l.u16(UInt16(type)); l.u16(0); l.u16(UInt16(subtables.count))
            var offset = 6 + 2 * subtables.count
            for s in subtables { l.u16(UInt16(offset)); offset += s.count }
            for s in subtables { l.bytes += s.bytes }
            return l
        }
        // A rule: after `before`, the glyph `glyph` goes through lookup `index`
        func rule(before: Int, glyph: Int, index: Int) -> Bytes {
            var r = Bytes()
            r.u16(3)
            r.u16(1); r.u16(18)
            r.u16(1); r.u16(24)
            r.u16(0)
            r.u16(1); r.u16(0); r.u16(UInt16(index))
            r.bytes += coverage([before]).bytes + coverage([glyph]).bytes
            return r
        }
        guard let toSecond = single(1) else { return nil }
        let toThird = single(2)
        var rules: [Bytes] = []
        for c in varied {
            guard let first = ids[GlyphKey(c, 0)], let second = ids[GlyphKey(c, 1)] else { continue }
            rules.append(rule(before: first, glyph: first, index: 1))
            if toThird != nil, ids[GlyphKey(c, 2)] != nil {
                rules.append(rule(before: second, glyph: first, index: 2))
            }
        }
        let lookups = [lookup(type: 6, subtables: rules), toSecond] + (toThird.map { [$0] } ?? [])

        var lookupList = Bytes()
        lookupList.u16(UInt16(lookups.count))
        var offset = 2 + 2 * lookups.count
        for l in lookups { lookupList.u16(UInt16(offset)); offset += l.count }
        for l in lookups { lookupList.bytes += l.bytes }

        var featureList = Bytes()
        featureList.u16(1)
        for c in "calt".utf8 { featureList.u8(c) }
        featureList.u16(8)
        featureList.u16(0); featureList.u16(1); featureList.u16(0)

        var scriptList = Bytes()
        scriptList.u16(2)
        let scriptSize = 4 + 8 // the script, then its default language
        for (i, tag) in ["DFLT", "latn"].enumerated() {
            for c in tag.utf8 { scriptList.u8(c) }
            scriptList.u16(UInt16(2 + 12 + i * scriptSize))
        }
        for _ in 0..<2 {
            scriptList.u16(4); scriptList.u16(0)
            scriptList.u16(0); scriptList.u16(0xFFFF); scriptList.u16(1); scriptList.u16(0)
        }

        var gsub = Bytes()
        gsub.u16(1); gsub.u16(0)
        gsub.u16(10)
        gsub.u16(UInt16(10 + scriptList.count))
        gsub.u16(UInt16(10 + scriptList.count + featureList.count))
        gsub.bytes += scriptList.bytes + featureList.bytes + lookupList.bytes
        return gsub
    }
}

// MARK: - TrueType

/// A TrueType font's bytes: the tables Core Text and Font Book need, and any more given.
private enum TrueType {
    static func font(entries: [DrawnFontFile.Entry], kerning: [UInt32: Int], family: String, style: DrawnFontStyle, slant: CGFloat,
                     postScriptName: String, unique: String, spacing: Int, extraTables: [(String, Bytes)]) -> Data {
        // Glyph 0 is .notdef and 1 the space, both without ink
        let space = DrawnFontFile.wordSpace + spacing
        let all = [DrawnFontFile.Glyph(contours: [], advance: 500, bounds: (0, 0, 0, 0)),
                   DrawnFontFile.Glyph(contours: [], advance: space, bounds: (0, 0, 0, 0))] + entries.map(\.glyph)
        var map: [UInt32: Int] = [32: 1, 0xA0: 1]
        for (i, entry) in entries.enumerated() {
            for code in entry.codes where map[code] == nil { map[code] = i + 2 }
        }
        let inked = all.filter { !$0.contours.isEmpty }
        let xMin = inked.map(\.bounds.xMin).min() ?? 0, yMin = inked.map(\.bounds.yMin).min() ?? 0
        let xMax = inked.map(\.bounds.xMax).max() ?? 0, yMax = inked.map(\.bounds.yMax).max() ?? 0

        // glyf and loca
        var glyf = Bytes(), loca = Bytes()
        for glyph in all {
            loca.u32(UInt32(glyf.count))
            guard !glyph.contours.isEmpty else { continue }
            glyf.i16(glyph.contours.count)
            glyf.i16(glyph.bounds.xMin); glyf.i16(glyph.bounds.yMin); glyf.i16(glyph.bounds.xMax); glyf.i16(glyph.bounds.yMax)
            var end = -1
            for contour in glyph.contours { end += contour.count; glyf.u16(UInt16(end)) }
            glyf.u16(0) // no instructions
            let points = glyph.contours.flatMap { $0 }
            for _ in points { glyf.u8(0x01) } // on the curve, coordinates as 16-bit deltas
            var last = 0
            for p in points { glyf.i16(p.x - last); last = p.x }
            last = 0
            for p in points { glyf.i16(p.y - last); last = p.y }
            glyf.pad()
        }
        loca.u32(UInt32(glyf.count))

        var hmtx = Bytes()
        for glyph in all { hmtx.u16(UInt16(glyph.advance)); hmtx.i16(glyph.bounds.xMin) }

        let maxPoints = all.map { $0.contours.reduce(0) { $0 + $1.count } }.max() ?? 0
        let maxContours = all.map(\.contours.count).max() ?? 0
        let advanceMax = all.map(\.advance).max() ?? 0
        let minRight = inked.map { $0.advance - $0.bounds.xMax }.min() ?? 0

        var head = Bytes()
        head.u32(0x0001_0000); head.u32(0x0001_0000)
        head.u32(0) // checksum adjustment, set last
        head.u32(0x5F0F_3CF5)
        head.u16(0x0003) // baseline at 0, left side bearing at x = 0
        head.u16(UInt16(DrawnFont.unitsPerEm))
        let since1904 = Int64(Date().timeIntervalSince1970) + 2_082_844_800
        head.i64(since1904); head.i64(since1904)
        head.i16(xMin); head.i16(yMin); head.i16(xMax); head.i16(yMax)
        head.u16((style.isBold ? 1 : 0) | (style.isItalic ? 2 : 0)) // macStyle
        head.u16(8) // smallest readable size
        head.i16(2) // fontDirectionHint
        head.i16(1) // long loca offsets
        head.i16(0)

        var hhea = Bytes()
        hhea.u32(0x0001_0000)
        hhea.i16(DrawnFontFile.ascender); hhea.i16(DrawnFontFile.descender); hhea.i16(0)
        hhea.u16(UInt16(advanceMax))
        hhea.i16(spacing); hhea.i16(minRight); hhea.i16(xMax)
        // The caret leans as the letters do
        hhea.i16(1000); hhea.i16(Int((tan(slant * .pi / 180) * 1000).rounded())); hhea.i16(0)
        for _ in 0..<4 { hhea.i16(0) }
        hhea.i16(0)
        hhea.u16(UInt16(all.count))

        var maxp = Bytes()
        maxp.u32(0x0001_0000)
        maxp.u16(UInt16(all.count)); maxp.u16(UInt16(maxPoints)); maxp.u16(UInt16(maxContours))
        maxp.u16(0); maxp.u16(0) // no composites
        maxp.u16(2) // zones
        for _ in 0..<8 { maxp.u16(0) } // no hinting

        var os2 = Bytes()
        os2.u16(4)
        os2.i16(inked.isEmpty ? 500 : inked.reduce(0) { $0 + $1.advance } / inked.count)
        os2.u16(style.isBold ? 700 : 400); os2.u16(5) // weight, medium width
        os2.u16(0) // installable
        for v in [650, 600, 0, 75, 650, 600, 0, 350] { os2.i16(v) } // subscripts and superscripts
        os2.i16(50); os2.i16(250) // strikeout
        os2.i16(0) // family class
        for _ in 0..<10 { os2.u8(0) } // PANOSE
        // Basic Latin, Latin-1 and general punctuation; miscellaneous symbols (bit 46); private use (bit 60)
        os2.u32(0b11 | 1 << 31); os2.u32(1 << 14 | 1 << 28); os2.u32(0); os2.u32(0)
        for c in "ARTS".utf8 { os2.u8(c) }
        // Italic, bold or regular, and the typographic metrics to be used
        os2.u16(UInt16((style.isItalic ? 0x01 : 0) | (style.isBold ? 0x20 : 0) | (style == .regular ? 0x40 : 0) | 0x80))
        let codes = map.keys.sorted()
        os2.u16(UInt16(codes.first ?? 32)); os2.u16(UInt16(min(codes.last ?? 32, 0xFFFF)))
        os2.i16(DrawnFontFile.ascender); os2.i16(DrawnFontFile.descender); os2.i16(0)
        os2.u16(UInt16(max(yMax, DrawnFontFile.ascender))); os2.u16(UInt16(max(-yMin, -DrawnFontFile.descender)))
        os2.u32(1); os2.u32(0) // Latin 1
        os2.i16(Int(DrawnFont.xHeight)); os2.i16(Int(DrawnFont.capHeight))
        os2.u16(0); os2.u16(32); os2.u16(1)

        let cmap = cmapTable(map)

        var post = Bytes()
        post.u32(0x0003_0000) // no glyph names
        post.u32(UInt32(bitPattern: Int32((-slant * 65536).rounded()))) // italic angle, leaning right
        post.i16(-100); post.i16(50)
        post.u32(0); post.u32(0); post.u32(0); post.u32(0); post.u32(0)

        let fullName = style == .regular ? family : "\(family) \(style.subfamily)"
        let name = nameTable([1: family, 2: style.subfamily, 3: unique, 4: fullName, 5: "Version 1.0", 6: postScriptName])

        // The tables in tag order, each on a four-byte boundary, with their checksums
        var tables: [(String, Bytes)] = [("OS/2", os2), ("cmap", cmap), ("glyf", glyf), ("head", head), ("hhea", hhea),
                                         ("hmtx", hmtx), ("loca", loca), ("maxp", maxp), ("name", name), ("post", post)]
        if !kerning.isEmpty { tables.append(("kern", kernTable(kerning))) }
        tables += extraTables
        tables.sort { Array($0.0.utf8).lexicographicallyPrecedes(Array($1.0.utf8)) }
        var font = Bytes()
        let count = tables.count
        let power = 1 << Int(log2(Double(count)))
        font.u32(0x0001_0000)
        font.u16(UInt16(count)); font.u16(UInt16(power * 16)); font.u16(UInt16(log2(Double(power)))); font.u16(UInt16(count * 16 - power * 16))
        var offset = 12 + 16 * count
        var headOffset = 0
        for (tag, table) in tables {
            for c in tag.utf8 { font.u8(c) }
            font.u32(table.checksum)
            font.u32(UInt32(offset))
            font.u32(UInt32(table.count))
            if tag == "head" { headOffset = offset }
            offset += (table.count + 3) & ~3
        }
        for (_, table) in tables {
            var padded = table
            padded.pad()
            font.bytes += padded.bytes
        }
        let adjustment = 0xB1B0_AFBA &- font.checksum
        font.set(u32: adjustment, at: headOffset + 8)
        return Data(font.bytes)
    }

    /// The classic kerning table: one horizontal subtable of pairs, sorted.
    static func kernTable(_ pairs: [UInt32: Int]) -> Bytes {
        let sorted = pairs.sorted { $0.key < $1.key }.prefix(10_000)
        let n = sorted.count
        let power = n > 0 ? 1 << Int(log2(Double(n))) : 0
        var kern = Bytes()
        kern.u16(0); kern.u16(1)
        kern.u16(0); kern.u16(UInt16(14 + 6 * n)); kern.u16(0x0001)
        kern.u16(UInt16(n)); kern.u16(UInt16(6 * power)); kern.u16(UInt16(n > 0 ? Int(log2(Double(power))) : 0))
        kern.u16(UInt16(6 * n - 6 * power))
        for (pair, value) in sorted {
            kern.u16(UInt16(pair >> 16)); kern.u16(UInt16(pair & 0xFFFF)); kern.i16(value)
        }
        return kern
    }

    /// Format 4: runs of characters with consecutive glyphs in one segment, and the closing one.
    static func cmapTable(_ map: [UInt32: Int]) -> Bytes {
        let codes = map.keys.sorted()
        var segments: [(start: UInt16, end: UInt16, delta: UInt16)] = []
        for code in codes {
            let glyph = map[code]!
            if let last = segments.last, UInt32(last.end) + 1 == code,
               Int(code) - Int(last.start) == glyph - Int(map[UInt32(last.start)]!) {
                segments[segments.count - 1].end = UInt16(code)
            } else {
                segments.append((UInt16(code), UInt16(code), UInt16(truncatingIfNeeded: glyph - Int(code))))
            }
        }
        segments.append((start: UInt16(0xFFFF), end: UInt16(0xFFFF), delta: UInt16(1)))
        var sub = Bytes()
        let segCount = segments.count
        let power = 1 << Int(log2(Double(segCount)))
        sub.u16(4)
        sub.u16(UInt16(16 + segCount * 8))
        sub.u16(0)
        sub.u16(UInt16(segCount * 2)); sub.u16(UInt16(power * 2)); sub.u16(UInt16(log2(Double(power)))); sub.u16(UInt16(segCount * 2 - power * 2))
        for s in segments { sub.u16(s.end) }
        sub.u16(0)
        for s in segments { sub.u16(s.start) }
        for s in segments { sub.u16(s.delta) }
        for _ in segments { sub.u16(0) }

        var cmap = Bytes()
        cmap.u16(0); cmap.u16(2)
        cmap.u16(0); cmap.u16(3); cmap.u32(12 + 8) // Unicode BMP
        cmap.u16(3); cmap.u16(1); cmap.u32(12 + 8) // Windows Unicode BMP, the same subtable
        cmap.bytes += sub.bytes
        return cmap
    }

    /// The names twice: Macintosh Roman (where the names have its letters) for older readers,
    /// then Windows English in UTF-16, the records in platform order as the format asks.
    static func nameTable(_ names: [Int: String]) -> Bytes {
        var strings = Bytes(), records = Bytes()
        var recordCount = 0
        let sorted = names.sorted { $0.key < $1.key }
        if sorted.allSatisfy({ $0.value.data(using: .macOSRoman) != nil }) {
            for (id, value) in sorted {
                let bytes = [UInt8](value.data(using: .macOSRoman)!)
                records.u16(1); records.u16(0); records.u16(0); records.u16(UInt16(id))
                records.u16(UInt16(bytes.count)); records.u16(UInt16(strings.count))
                strings.bytes += bytes
                recordCount += 1
            }
        }
        for (id, value) in sorted {
            let utf16 = Array(value.utf16)
            records.u16(3); records.u16(1); records.u16(0x0409); records.u16(UInt16(id))
            records.u16(UInt16(utf16.count * 2)); records.u16(UInt16(strings.count))
            for unit in utf16 { strings.u16(unit) }
            recordCount += 1
        }
        var name = Bytes()
        name.u16(0); name.u16(UInt16(recordCount)); name.u16(UInt16(6 + records.count))
        name.bytes += records.bytes + strings.bytes
        return name
    }
}

/// Big-endian bytes.
struct Bytes {
    var bytes: [UInt8] = []
    var count: Int { bytes.count }

    mutating func u8(_ v: UInt8) { bytes.append(v) }
    mutating func u16(_ v: UInt16) { bytes += [UInt8(v >> 8), UInt8(v & 0xFF)] }
    mutating func i16(_ v: Int) { u16(UInt16(bitPattern: Int16(clamping: v))) }
    mutating func u32(_ v: UInt32) { bytes += [UInt8(v >> 24), UInt8((v >> 16) & 0xFF), UInt8((v >> 8) & 0xFF), UInt8(v & 0xFF)] }
    mutating func i64(_ v: Int64) { u32(UInt32(truncatingIfNeeded: v >> 32)); u32(UInt32(truncatingIfNeeded: v)) }
    mutating func pad() { while bytes.count % 4 != 0 { bytes.append(0) } }
    mutating func set(u32 v: UInt32, at offset: Int) {
        bytes[offset] = UInt8(v >> 24); bytes[offset + 1] = UInt8((v >> 16) & 0xFF)
        bytes[offset + 2] = UInt8((v >> 8) & 0xFF); bytes[offset + 3] = UInt8(v & 0xFF)
    }

    /// The sum of its big-endian 32-bit words, zero-padded.
    var checksum: UInt32 {
        var sum: UInt32 = 0
        var i = 0
        while i < bytes.count {
            var word: UInt32 = 0
            for k in 0..<4 { word = word << 8 | UInt32(i + k < bytes.count ? bytes[i + k] : 0) }
            sum &+= word
            i += 4
        }
        return sum
    }
}
