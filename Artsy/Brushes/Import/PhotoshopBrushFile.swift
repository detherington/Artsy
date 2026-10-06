import Foundation

/// Photoshop's `.abr` brush file, as far as its sampled tips go. Adobe has not published
/// the format; this follows what GIMP and Krita worked out. Versions 1 and 2 are a list of
/// brushes; version 6 (Photoshop 7 and later) keeps the tips in an `8BIM samp` section.
/// Brush dynamics and patterns are not read; names are, from the `desc` section, where a
/// brush preset names the sampled tip it uses by key.
enum PhotoshopBrushFile {
    /// One sampled tip: 8-bit coverage, 255 where the brush paints — as the file stores it
    /// (checked against brushes from the wild: their borders are 0, their marks bright;
    /// Krita's loader inverts them into its own black-paints images).
    struct Tip {
        let name: String?
        let width: Int
        let height: Int
        let coverage: [UInt8]
    }

    enum ABRError: LocalizedError {
        case notABrushFile
        case unsupportedVersion(Int)
        case damaged

        var errorDescription: String? {
            switch self {
            case .notABrushFile: return "The file is not a Photoshop brush file."
            case .unsupportedVersion(let v): return "Photoshop brush version \(v) is not supported."
            case .damaged: return "The Photoshop brush file is damaged."
            }
        }
    }

    static func tips(in data: Data) throws -> [Tip] {
        var reader = Reader(data: data)
        guard data.count >= 4 else { throw ABRError.notABrushFile }
        let version = Int(try reader.short())
        switch version {
        case 1, 2:
            return try oldTips(&reader, version: version)
        case 6, 7, 8, 9, 10:
            let subversion = Int(try reader.short())
            return try newTips(&reader, subversion: subversion)
        default:
            throw ABRError.unsupportedVersion(version)
        }
    }

    // MARK: - Versions 1 and 2

    private static func oldTips(_ reader: inout Reader, version: Int) throws -> [Tip] {
        let count = Int(try reader.short())
        var tips: [Tip] = []
        for _ in 0..<count {
            let type = try reader.short()
            let size = Int(try reader.long())
            let next = reader.offset + size
            if type != 2 {   // 1 is a computed (round) brush; nothing to import
                reader.offset = next
                continue
            }
            _ = try reader.long()    // misc
            _ = try reader.short()   // spacing
            var name: String?
            if version == 2 {
                let characters = Int(try reader.long())
                let bytes = try reader.bytes(characters * 2)
                name = String(utf16CodeUnits: stride(from: 0, to: bytes.count - 1, by: 2).map { UInt16(bytes[$0]) << 8 | UInt16(bytes[$0 + 1]) },
                              count: characters).trimmingCharacters(in: CharacterSet(charactersIn: "\0"))
            }
            _ = try reader.byte()    // antialiasing
            for _ in 0..<4 { _ = try reader.short() }   // short bounds
            let top = Int(try reader.long()), left = Int(try reader.long())
            let bottom = Int(try reader.long()), right = Int(try reader.long())
            let depth = Int(try reader.short())
            let compression = try reader.byte()
            if let tip = try readTip(&reader, name: name, width: right - left, height: bottom - top, depth: depth, compressed: compression != 0) {
                tips.append(tip)
            }
            reader.offset = next
        }
        return tips
    }

    // MARK: - Version 6

    private static func newTips(_ reader: inout Reader, subversion: Int) throws -> [Tip] {
        var sampled: [(key: String, tip: Tip)] = []
        var names: [String: String] = [:]

        // Sections: "8BIM", a four-letter name, a length, the contents. The tips are in
        // `samp`, their names in `desc`, in either order.
        while reader.offset + 12 <= reader.data.count {
            let tag = try reader.bytes(4)
            guard tag == Array("8BIM".utf8) else { throw ABRError.damaged }
            let sectionName = String(decoding: try reader.bytes(4), as: UTF8.self)
            let length = Int(try reader.long())
            let end = min(reader.offset + length, reader.data.count)
            switch sectionName {
            case "samp":
                while reader.offset < end {
                    let size = Int(try reader.long())
                    guard size > 0 else { throw ABRError.damaged }   // or the loop would never move on
                    var next = reader.offset + size
                    while next % 4 != 0 { next += 1 }   // padded to four bytes
                    let key = Self.key(from: try reader.bytes(37))   // the tip's id, which `desc` refers to
                    _ = try reader.bytes(subversion == 1 ? 10 : 264)
                    let top = Int(try reader.long()), left = Int(try reader.long())
                    let bottom = Int(try reader.long()), right = Int(try reader.long())
                    let depth = Int(try reader.short())
                    let compression = try reader.byte()
                    if let tip = try readTip(&reader, name: nil, width: right - left, height: bottom - top, depth: depth,
                                             compressed: compression != 0) {
                        sampled.append((key, tip))
                    }
                    reader.offset = next
                }
            case "desc":
                names = sampledNames(in: reader.data[(reader.data.startIndex + reader.offset)..<(reader.data.startIndex + end)])
            default:
                break
            }
            reader.offset = end
        }
        return sampled.map { key, tip in
            Tip(name: names[key], width: tip.width, height: tip.height, coverage: tip.coverage)
        }
    }

    /// A sample record's 37-byte key as `desc` writes it: without the leading `$`, or any
    /// trailing nulls.
    private static func key(from bytes: [UInt8]) -> String {
        let text = String(decoding: bytes.prefix { $0 != 0 }, as: UTF8.self)
        return text.hasPrefix("$") ? String(text.dropFirst()) : text
    }

    /// Names of sampled tips, by key, from a `desc` section. Each brush preset there has a
    /// `Nm  ` text and, for a sampled tip, a `sampledData` text holding the tip's key. The
    /// descriptor structure is not walked; a key takes the name that came before it.
    private static func sampledNames(in desc: Data) -> [String: String] {
        // A descriptor key is a 4-byte length (0 for a four-letter key) then the key, then
        // the value's type; a TEXT value is a 4-byte count of UTF-16 units, null included.
        func texts(after marker: [UInt8]) -> [(position: Int, text: String)] {
            var found: [(Int, String)] = []
            var searchFrom = desc.startIndex
            while let range = desc.range(of: Data(marker), in: searchFrom..<desc.endIndex) {
                searchFrom = range.upperBound
                guard range.upperBound + 4 <= desc.endIndex else { break }
                let count = desc[range.upperBound..<range.upperBound + 4].reduce(0) { $0 << 8 | Int($1) }
                let bytesEnd = range.upperBound + 4 + count * 2
                guard count > 0, count < 1024, bytesEnd <= desc.endIndex else { continue }
                let units = stride(from: range.upperBound + 4, to: bytesEnd - 1, by: 2).map {
                    UInt16(desc[$0]) << 8 | UInt16(desc[$0 + 1])
                }
                let text = String(utf16CodeUnits: units, count: units.count).trimmingCharacters(in: CharacterSet(charactersIn: "\0"))
                found.append((range.lowerBound - desc.startIndex, text))
            }
            return found
        }
        let names = texts(after: [0, 0, 0, 0] + Array("Nm  TEXT".utf8))
        let keys = texts(after: [0, 0, 0, 11] + Array("sampledDataTEXT".utf8))
        var result: [String: String] = [:]
        for (position, key) in keys {
            if let name = names.last(where: { $0.position < position })?.text, !name.isEmpty, result[key] == nil {
                result[key] = name
            }
        }
        return result
    }

    // MARK: - Pixels

    private static func readTip(_ reader: inout Reader, name: String?, width: Int, height: Int, depth: Int,
                                compressed: Bool) throws -> Tip? {
        guard width > 0, height > 0, width <= 8192, height <= 8192, depth == 8 || depth == 16 else { return nil }
        let bytesPerPixel = depth / 8
        var pixels: [UInt8]
        if compressed {
            pixels = try unpackBits(&reader, rows: height, bytesPerRow: width * bytesPerPixel)
        } else {
            pixels = try reader.bytes(width * height * bytesPerPixel)
        }
        if depth == 16 {
            pixels = stride(from: 0, to: pixels.count - 1, by: 2).map { pixels[$0] }   // high byte
        }
        // A tip with nothing in it would be a brush that draws nothing
        guard pixels.contains(where: { $0 > 0 }) else { return nil }
        return Tip(name: name, width: width, height: height, coverage: pixels)
    }

    /// PackBits, one scanline at a time: the compressed length of every row first, then the
    /// rows. A count byte n ≥ 0 means copy n + 1 bytes; n < 0 means repeat the next byte
    /// 1 − n times; −128 is skipped.
    private static func unpackBits(_ reader: inout Reader, rows: Int, bytesPerRow: Int) throws -> [UInt8] {
        var lengths: [Int] = []
        for _ in 0..<rows { lengths.append(Int(try reader.short())) }
        var out: [UInt8] = []
        out.reserveCapacity(rows * bytesPerRow)
        for length in lengths {
            let rowEnd = reader.offset + length
            var row: [UInt8] = []
            while reader.offset < rowEnd {
                let n = Int(Int8(bitPattern: try reader.byte()))
                if n >= 0 {
                    row += try reader.bytes(n + 1)
                } else if n != -128 {
                    row += [UInt8](repeating: try reader.byte(), count: 1 - n)
                }
            }
            guard row.count >= bytesPerRow else { throw ABRError.damaged }
            out += row.prefix(bytesPerRow)
        }
        return out
    }

    /// Big-endian reads with bounds checks.
    private struct Reader {
        let data: Data
        var offset = 0

        mutating func bytes(_ count: Int) throws -> [UInt8] {
            guard count >= 0, offset + count <= data.count else { throw ABRError.damaged }
            defer { offset += count }
            return Array(data[(data.startIndex + offset)..<(data.startIndex + offset + count)])
        }

        mutating func byte() throws -> UInt8 { try bytes(1)[0] }

        mutating func short() throws -> UInt16 {
            let b = try bytes(2)
            return UInt16(b[0]) << 8 | UInt16(b[1])
        }

        mutating func long() throws -> UInt32 {
            let b = try bytes(4)
            return UInt32(b[0]) << 24 | UInt32(b[1]) << 16 | UInt32(b[2]) << 8 | UInt32(b[3])
        }
    }
}
