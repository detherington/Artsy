import Foundation
import CoreGraphics
import ImageIO

/// A Procreate `.brush`: a ZIP holding `Shape.png` (the tip, white where it paints),
/// `Grain.png` (the texture, bright where the paper is high) and `Brush.archive`, a keyed
/// archive of settings that is not read. A `.brushset` is a ZIP of `.brush` folders.
/// The format is not published; this follows what has been worked out from the files.
enum ProcreateBrushFile {
    struct Brush {
        /// The folder name inside a set, or the file's own name.
        let name: String
        let shape: CGImage?
        let grain: CGImage?
    }

    enum ProcreateError: LocalizedError {
        case nothingInside

        var errorDescription: String? {
            switch self {
            case .nothingInside: return "No Procreate brush was found inside the file."
            }
        }
    }

    /// Every brush in a `.brush` or `.brushset`.
    static func brushes(in data: Data, fileName: String) throws -> [Brush] {
        let archive = try ZipArchive(data: data)
        // A set keeps each brush in its own folder; a single brush has its files at the top
        var folders = Set(archive.entries.compactMap { entry -> String? in
            let parts = entry.name.split(separator: "/", omittingEmptySubsequences: true)
            return parts.count >= 2 && parts.last.map { $0.hasSuffix(".png") || $0 == "Brush.archive" } == true
                ? parts.dropLast().joined(separator: "/") + "/" : nil
        })
        if folders.isEmpty { folders.insert("") }

        let brushes = try folders.sorted().compactMap { folder -> Brush? in
            let shape = try archive.contents(of: folder + "Shape.png").flatMap(image(from:))
            let grain = try archive.contents(of: folder + "Grain.png").flatMap(image(from:))
            guard shape != nil || grain != nil else { return nil }
            let name = folder.isEmpty ? fileName : String(folder.dropLast().split(separator: "/").last ?? Substring(fileName))
            return Brush(name: name.replacingOccurrences(of: ".brush", with: ""), shape: shape, grain: grain)
        }
        guard !brushes.isEmpty else { throw ProcreateError.nothingInside }
        return brushes
    }

    private static func image(from data: Data) -> CGImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(source, 0, nil)
    }
}
