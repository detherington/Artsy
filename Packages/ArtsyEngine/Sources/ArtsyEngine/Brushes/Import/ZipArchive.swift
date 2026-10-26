import Foundation
import Compression

/// Enough of the ZIP format to read a Procreate brush: the central directory, and entries
/// stored flat or deflated. Not a general ZIP library.
struct ZipArchive {
    struct Entry {
        let name: String
        let method: UInt16
        let compressedSize: Int
        let uncompressedSize: Int
        let localHeaderOffset: Int
    }

    let data: Data
    private(set) var entries: [Entry] = []

    enum ZipError: LocalizedError {
        case notAZip
        case unsupportedCompression(UInt16)
        case corrupt(String)

        var errorDescription: String? {
            switch self {
            case .notAZip: return "The file is not a ZIP archive."
            case .unsupportedCompression(let method): return "The archive uses an unsupported compression (\(method))."
            case .corrupt(let name): return "The archive entry \(name) is damaged."
            }
        }
    }

    init(data: Data) throws {
        self.data = data
        // The end-of-central-directory record is in the last 64 KB, found by its signature
        guard data.count >= 22 else { throw ZipError.notAZip }
        let searchStart = max(0, data.count - 65_557)
        var eocd: Int?
        var i = data.count - 22
        while i >= searchStart {
            if u32(at: i) == 0x06054b50 { eocd = i; break }
            i -= 1
        }
        guard let eocd else { throw ZipError.notAZip }
        let count = Int(u16(at: eocd + 10))
        var offset = Int(u32(at: eocd + 16))

        for _ in 0..<count {
            guard offset + 46 <= data.count, u32(at: offset) == 0x02014b50 else { throw ZipError.corrupt("central directory") }
            let method = u16(at: offset + 10)
            let compressedSize = Int(u32(at: offset + 20))
            let uncompressedSize = Int(u32(at: offset + 24))
            let nameLength = Int(u16(at: offset + 28))
            let extraLength = Int(u16(at: offset + 30))
            let commentLength = Int(u16(at: offset + 32))
            let localHeaderOffset = Int(u32(at: offset + 42))
            guard offset + 46 + nameLength <= data.count else { throw ZipError.corrupt("central directory") }
            let name = String(decoding: data[(data.startIndex + offset + 46)..<(data.startIndex + offset + 46 + nameLength)], as: UTF8.self)
            entries.append(Entry(name: name, method: method, compressedSize: compressedSize,
                                 uncompressedSize: uncompressedSize, localHeaderOffset: localHeaderOffset))
            offset += 46 + nameLength + extraLength + commentLength
        }
    }

    /// The contents of the entry with this exact name, or nil if there is none.
    func contents(of name: String) throws -> Data? {
        guard let entry = entries.first(where: { $0.name == name }) else { return nil }
        return try contents(of: entry)
    }

    func contents(of entry: Entry) throws -> Data {
        let header = entry.localHeaderOffset
        guard header + 30 <= data.count, u32(at: header) == 0x04034b50 else { throw ZipError.corrupt(entry.name) }
        let nameLength = Int(u16(at: header + 26))
        let extraLength = Int(u16(at: header + 28))
        let start = header + 30 + nameLength + extraLength
        guard start + entry.compressedSize <= data.count else { throw ZipError.corrupt(entry.name) }
        let compressed = data[(data.startIndex + start)..<(data.startIndex + start + entry.compressedSize)]

        switch entry.method {
        case 0:
            return Data(compressed)
        case 8:
            guard entry.uncompressedSize > 0 else { return Data() }
            // A brush's images are a few megabytes; the header's size is untrusted
            guard entry.uncompressedSize <= 256 << 20 else { throw ZipError.corrupt(entry.name) }
            var output = Data(count: entry.uncompressedSize)
            let written = output.withUnsafeMutableBytes { out -> Int in
                compressed.withUnsafeBytes { input -> Int in
                    compression_decode_buffer(out.baseAddress!.assumingMemoryBound(to: UInt8.self), entry.uncompressedSize,
                                              input.baseAddress!.assumingMemoryBound(to: UInt8.self), compressed.count,
                                              nil, COMPRESSION_ZLIB)
                }
            }
            guard written == entry.uncompressedSize else { throw ZipError.corrupt(entry.name) }
            return output
        default:
            throw ZipError.unsupportedCompression(entry.method)
        }
    }

    private func u16(at offset: Int) -> UInt16 {
        let i = data.startIndex + offset
        return UInt16(data[i]) | UInt16(data[i + 1]) << 8
    }

    private func u32(at offset: Int) -> UInt32 {
        let i = data.startIndex + offset
        return UInt32(data[i]) | UInt32(data[i + 1]) << 8 | UInt32(data[i + 2]) << 16 | UInt32(data[i + 3]) << 24
    }
}
