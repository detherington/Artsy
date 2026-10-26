import Foundation
import CoreGraphics
import ImageIO

/// A Procreate `.brush`: a ZIP holding `Shape.png` (the tip, white where it paints),
/// `Grain.png` (the texture, bright where the paper is high) and `Brush.archive`, a keyed
/// archive of its settings, beside a `Signature` and a `QuickLook` folder. A `.brushset` is
/// a ZIP of such folders, one per brush, each with a `Reset` copy of its defaults, and a
/// `brushset.plist` giving their order. A dual brush keeps its second brush in a `Sub01`
/// folder. The format is not published; this follows what has been worked out from the
/// files.
enum ProcreateBrushFile {
    struct Brush {
        /// The archive's name for the brush, else the folder's or the file's.
        let name: String
        let shape: CGImage?
        let grain: CGImage?
        /// A dual brush's second shape, from its `Sub01` folder.
        let secondShape: CGImage?
        let settings: Settings?
    }

    /// What `Brush.archive` says, of the settings the importer maps. Readings of an
    /// unpublished format, so each is optional and taken with care.
    struct Settings: Equatable {
        var name: String?
        /// `plotSpacing`: near 0 for a dense inker. Looks like the square of the slider's
        /// fraction (a 5% brush stores 0.0025).
        var spacing: Float?
        /// `paintSize`, 0...1 of the size slider.
        var size: Float?
        /// `dynamicsPressureSize` and `dynamicsPressureOpacity`: how much pressure does, 0...1.
        var pressureSize: Float?
        var pressureOpacity: Float?
        /// `shapeScatter`, 0...1.
        var scatter: Float?
        /// `shapeRotation`: 1 turns the tip with the stroke.
        var rotation: Float?
        /// `shapeRandomise`: a random angle per dab.
        var randomRotation = false
        var sizeJitter: Float?
        var opacityJitter: Float?
        /// `grainDepth`, 0...1.
        var grainDepth: Float?
        /// `shapeInverted` and `textureInverted`: the images are to be read the other way up.
        var shapeInverted = false
        var grainInverted = false

        init() {}

        /// Read from the keyed archive. Procreate's own classes stand in as plain bags of
        /// the values the importer uses; nothing else in the archive is decoded.
        init?(archive data: Data) {
            guard let unarchiver = try? NSKeyedUnarchiver(forReadingFrom: data) else { return nil }
            unarchiver.requiresSecureCoding = false
            unarchiver.decodingFailurePolicy = .setErrorAndReturn
            unarchiver.setClass(ProcreateArchiveShell.self, forClassName: "SilicaBrush")
            let root = unarchiver.decodeObject(forKey: "root")
            unarchiver.finishDecoding()
            let values: [String: Any]
            if let shell = root as? ProcreateArchiveShell { values = shell.values }
            else if let dictionary = root as? [String: Any] { values = dictionary }
            else { return nil }

            func number(_ key: String) -> Float? { (values[key] as? NSNumber).map { $0.floatValue } }
            func flag(_ key: String) -> Bool { (values[key] as? NSNumber)?.boolValue ?? false }
            name = (values["name"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            spacing = number("plotSpacing")
            size = number("paintSize")
            pressureSize = number("dynamicsPressureSize")
            pressureOpacity = number("dynamicsPressureOpacity")
            scatter = number("shapeScatter")
            rotation = number("shapeRotation")
            randomRotation = flag("shapeRandomise")
            sizeJitter = number("dynamicsJitterSize")
            opacityJitter = number("dynamicsJitterOpacity")
            grainDepth = number("grainDepth")
            shapeInverted = flag("shapeInverted")
            grainInverted = flag("textureInverted")
        }
    }

    enum ProcreateError: LocalizedError {
        case nothingInside

        var errorDescription: String? {
            switch self {
            case .nothingInside: return "No Procreate brush was found inside the file."
            }
        }
    }

    /// The files that make a folder a brush.
    private static let brushFiles: Set<String> = ["Shape.png", "Grain.png", "Brush.archive"]

    /// Every brush in a `.brush` or `.brushset`, in the set's own order.
    static func brushes(in data: Data, fileName: String) throws -> [Brush] {
        let archive = try ZipArchive(data: data)

        // A brush is wherever its files sit: at the top of a .brush, in a folder per brush
        // in a .brushset. Not the Reset folder a brush keeps its defaults in, nor a dual
        // brush's Sub01 (that is part of its brush), nor the signature and preview folders,
        // which hold only pictures.
        var folders = Set<String>()
        for entry in archive.entries {
            let parts = entry.name.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
            guard let last = parts.last, brushFiles.contains(last) else { continue }
            let folder = parts.dropLast()
            if folder.contains("Reset") || folder.last.map({ $0.hasPrefix("Sub") }) == true { continue }
            folders.insert(folder.isEmpty ? "" : folder.joined(separator: "/") + "/")
        }

        var ordered = folders.sorted()
        if let plist = try archive.contents(of: "brushset.plist"),
           let list = try? PropertyListSerialization.propertyList(from: plist, format: nil) as? [String: Any],
           let order = list["brushes"] as? [String] {
            let listed = order.map { $0 + "/" }.filter(folders.contains)
            ordered = listed + ordered.filter { !listed.contains($0) }
        }

        let brushes = try ordered.compactMap { folder -> Brush? in
            let shape = try archive.contents(of: folder + "Shape.png").flatMap(image(from:))
            let grain = try archive.contents(of: folder + "Grain.png").flatMap(image(from:))
            guard shape != nil || grain != nil else { return nil }
            let secondShape = try archive.contents(of: folder + "Sub01/Shape.png").flatMap(image(from:))
            let settings = try archive.contents(of: folder + "Brush.archive").flatMap { Settings(archive: $0) }
            let folderName = folder.isEmpty ? fileName : String(folder.dropLast().split(separator: "/").last ?? Substring(fileName))
            let name = settings?.name ?? folderName.replacingOccurrences(of: ".brush", with: "")
            return Brush(name: name, shape: shape, grain: grain, secondShape: secondShape, settings: settings)
        }
        guard !brushes.isEmpty else { throw ProcreateError.nothingInside }
        return brushes
    }

    private static func image(from data: Data) -> CGImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(source, 0, nil)
    }
}

/// Stands in for Procreate's own classes when a `Brush.archive` is unarchived: keeps the
/// values of the keys the importer reads, decodes nothing else.
final class ProcreateArchiveShell: NSObject, NSCoding {
    static let keys = [
        "name", "plotSpacing", "paintSize", "dynamicsPressureSize", "dynamicsPressureOpacity", "shapeScatter",
        "shapeRotation", "shapeRandomise", "dynamicsJitterSize", "dynamicsJitterOpacity", "grainDepth",
        "shapeInverted", "textureInverted",
    ]
    let values: [String: Any]

    init?(coder: NSCoder) {
        var values: [String: Any] = [:]
        for key in Self.keys where coder.containsValue(forKey: key) {
            if let value = coder.decodeObject(forKey: key) { values[key] = value }
        }
        self.values = values
    }

    func encode(with coder: NSCoder) {}
}
