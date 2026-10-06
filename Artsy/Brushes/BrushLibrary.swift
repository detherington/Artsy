import Foundation
import AppKit
import UniformTypeIdentifiers

/// Every brush the app knows: the built-ins, plus the user's own, which live as one JSON
/// file each in `~/Library/Application Support/Artsy/Brushes/`. Tip and grain images those
/// brushes use live beside them in `Textures/`.
///
/// A brush file (`.artsybrush`) is `{"format": 1, "brush": <BrushDescriptor>}`.
final class BrushLibrary: ObservableObject {
    static let shared = BrushLibrary(directory: defaultDirectory)

    static let fileExtension = "artsybrush"
    static let brushType = UTType(exportedAs: "com.artsy.brush", conformingTo: .json)
    static let formatVersion = 1

    let directory: URL
    var texturesDirectory: URL { directory.appendingPathComponent("Textures", isDirectory: true) }

    /// The user's brushes, in the order they were made.
    @Published private(set) var userBrushes: [BrushDescriptor] = []

    /// Built-in brushes followed by the user's.
    var all: [BrushDescriptor] { BrushDescriptor.allDefaults + userBrushes }

    static var defaultDirectory: URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return support.appendingPathComponent("Artsy/Brushes", isDirectory: true)
    }

    init(directory: URL) {
        self.directory = directory
        try? FileManager.default.createDirectory(at: texturesDirectory, withIntermediateDirectories: true)
        load()
    }

    // MARK: - Lookup

    func brush(id: UUID) -> BrushDescriptor? {
        (all + [.eraser]).first { $0.id == id }
    }

    func brush(named name: String) -> BrushDescriptor? {
        (all + [.eraser]).first { $0.name == name }
    }

    func isUserBrush(_ brush: BrushDescriptor) -> Bool {
        userBrushes.contains { $0.id == brush.id }
    }

    // MARK: - Changing the library

    /// A new user brush based on `brush`, saved. The copy gets a fresh id and a name that
    /// is not already taken.
    @discardableResult
    func duplicate(_ brush: BrushDescriptor) throws -> BrushDescriptor {
        let copy = BrushDescriptor(copying: brush, id: UUID(), name: untakenName(basedOn: brush.name))
        try save(copy)
        return copy
    }

    /// Save a user brush, new or changed.
    func save(_ brush: BrushDescriptor) throws {
        let file = BrushFile(brush: brush)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try encoder.encode(file).write(to: url(for: brush.id), options: .atomic)
        if let index = userBrushes.firstIndex(where: { $0.id == brush.id }) {
            userBrushes[index] = brush
        } else {
            userBrushes.append(brush)
        }
    }

    func remove(_ brush: BrushDescriptor) throws {
        guard isUserBrush(brush) else { return }
        try FileManager.default.removeItem(at: url(for: brush.id))
        userBrushes.removeAll { $0.id == brush.id }
    }

    /// Copy a brush file into the library. The brush keeps its id unless that id is
    /// already in use, and gets an untaken name.
    @discardableResult
    func importBrush(from source: URL) throws -> BrushDescriptor {
        let file = try JSONDecoder().decode(BrushFile.self, from: Data(contentsOf: source))
        guard file.format <= Self.formatVersion else { throw LibraryError.newerFormat(file.format) }
        var imported = file.brush
        let idTaken = brush(id: imported.id) != nil
        if idTaken || brush(named: imported.name) != nil {
            imported = BrushDescriptor(copying: imported, id: idTaken ? UUID() : imported.id,
                                       name: untakenName(basedOn: imported.name))
        }
        try save(imported)
        return imported
    }

    /// Import whatever brushes a file holds: an `.artsybrush`, a Photoshop `.abr` (its
    /// sampled tips, one brush each), or a Procreate `.brush` or `.brushset` (shape and
    /// grain, one brush each; settings are not read). Images go into the textures folder;
    /// the brushes made from them are stamp brushes with plain defaults, to be tuned in the
    /// Brush Studio.
    @discardableResult
    func importBrushes(from source: URL) throws -> [BrushDescriptor] {
        let stem = source.deletingPathExtension().lastPathComponent
        switch source.pathExtension.lowercased() {
        case "abr":
            let tips = try PhotoshopBrushFile.tips(in: Data(contentsOf: source))
            return try tips.enumerated().map { index, tip in
                let imageName = try saveTexture(coverage: tip.coverage, width: tip.width, height: tip.height,
                                                basedOn: tips.count == 1 ? stem : "\(stem) \(index + 1)")
                var brush = BrushDescriptor(copying: .hardRound, id: UUID(),
                                            name: untakenName(basedOn: tip.name ?? (tips.count == 1 ? stem : "\(stem) \(index + 1)"), copy: false))
                brush.category = .painting
                brush.hardness = 1
                brush.rendering = .stamp(StampSettings(tip: .image(imageName), spacing: 0.15, flow: 0.8, followsDirection: true))
                try save(brush)
                return brush
            }
        case "brush", "brushset":
            let found = try ProcreateBrushFile.brushes(in: Data(contentsOf: source), fileName: stem)
            return try found.map { imported in
                var settings = StampSettings(spacing: 0.1, flow: 0.7)
                if let shape = imported.shape {
                    let (pixels, width, height) = try Self.brightness(of: shape)
                    settings.tip = .image(try saveTexture(coverage: pixels, width: width, height: height, basedOn: imported.name + " shape"))
                }
                if let grain = imported.grain {
                    let (pixels, width, height) = try Self.brightness(of: grain)
                    let name = try saveTexture(height: pixels, width: width, height: height, basedOn: imported.name + " grain")
                    settings.grain = .init(mode: .multiply, texture: .image(name), attachment: .canvas, scale: 1, depth: 0.5)
                }
                var brush = BrushDescriptor(copying: .hardRound, id: UUID(), name: untakenName(basedOn: imported.name, copy: false))
                brush.category = .painting
                brush.hardness = 1
                brush.rendering = .stamp(settings)
                try save(brush)
                return brush
            }
        default:
            return [try importBrush(from: source)]
        }
    }

    /// Write 8-bit coverage as a PNG whose alpha channel is the shape, named after `basedOn`.
    private func saveTexture(coverage: [UInt8], width: Int, height: Int, basedOn: String) throws -> String {
        var rgba = [UInt8](repeating: 0, count: width * height * 4)
        for i in 0..<(width * height) { rgba[i * 4 + 3] = coverage[i] }
        return try saveTexturePNG(rgba: rgba, width: width, height: height, alpha: true, basedOn: basedOn)
    }

    /// Write 8-bit height as a flat grey PNG (brightness is height), named after `basedOn`.
    private func saveTexture(height pixels: [UInt8], width: Int, height: Int, basedOn: String) throws -> String {
        var rgba = [UInt8](repeating: 255, count: width * height * 4)
        for i in 0..<(width * height) {
            rgba[i * 4] = pixels[i]; rgba[i * 4 + 1] = pixels[i]; rgba[i * 4 + 2] = pixels[i]
        }
        return try saveTexturePNG(rgba: rgba, width: width, height: height, alpha: false, basedOn: basedOn)
    }

    private func saveTexturePNG(rgba: [UInt8], width: Int, height: Int, alpha: Bool, basedOn: String) throws -> String {
        var pixels = rgba
        let image = pixels.withUnsafeMutableBytes { raw -> CGImage? in
            CGContext(data: raw.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                      space: CGColorSpaceCreateDeviceRGB(),
                      bitmapInfo: (alpha ? CGImageAlphaInfo.premultipliedLast : CGImageAlphaInfo.noneSkipLast).rawValue)?.makeImage()
        }
        guard let image else { throw LibraryError.unreadableImage(basedOn) }
        let base = basedOn.replacingOccurrences(of: ":", with: "-").replacingOccurrences(of: "/", with: "-")
        var name = base + ".png"
        var counter = 2
        while FileManager.default.fileExists(atPath: texturesDirectory.appendingPathComponent(name).path) {
            name = "\(base) \(counter).png"
            counter += 1
        }
        let destination = texturesDirectory.appendingPathComponent(name)
        guard let sink = CGImageDestinationCreateWithURL(destination as CFURL, UTType.png.identifier as CFString, 1, nil) else {
            throw LibraryError.unreadableImage(basedOn)
        }
        CGImageDestinationAddImage(sink, image, nil)
        guard CGImageDestinationFinalize(sink) else { throw LibraryError.unreadableImage(basedOn) }
        return name
    }

    /// An image's brightness, 8-bit, row by row.
    private static func brightness(of image: CGImage) throws -> ([UInt8], Int, Int) {
        let width = image.width, height = image.height
        guard width > 0, height > 0, width <= 4096, height <= 4096 else { throw LibraryError.unreadableImage("image") }
        var grey = [UInt8](repeating: 0, count: width * height)
        let drawn = grey.withUnsafeMutableBytes { raw -> Bool in
            guard let context = CGContext(data: raw.baseAddress, width: width, height: height, bitsPerComponent: 8,
                                          bytesPerRow: width, space: CGColorSpaceCreateDeviceGray(),
                                          bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard drawn else { throw LibraryError.unreadableImage("image") }
        return (grey, width, height)
    }

    func export(_ brush: BrushDescriptor, to destination: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(BrushFile(brush: brush)).write(to: destination, options: .atomic)
    }

    // MARK: - Tip and grain images

    /// Copy an image into the textures folder as a PNG and return the name a brush refers
    /// to it by. PNG, JPEG, TIFF and other images macOS reads are accepted, as are GIMP
    /// `.gbr` brushes.
    @discardableResult
    func importTexture(from source: URL) throws -> String {
        let cgImage: CGImage
        if source.pathExtension.lowercased() == "gbr" {
            cgImage = try GimpBrushFile.image(from: Data(contentsOf: source))
        } else {
            guard let image = NSImage(contentsOf: source),
                  let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
                throw LibraryError.unreadableImage(source.lastPathComponent)
            }
            cgImage = cg
        }

        let base = source.deletingPathExtension().lastPathComponent
            .replacingOccurrences(of: ":", with: "-")
        var name = base + ".png"
        var counter = 2
        while FileManager.default.fileExists(atPath: texturesDirectory.appendingPathComponent(name).path) {
            name = "\(base) \(counter).png"
            counter += 1
        }
        let destination = texturesDirectory.appendingPathComponent(name)
        guard let sink = CGImageDestinationCreateWithURL(destination as CFURL, UTType.png.identifier as CFString, 1, nil) else {
            throw LibraryError.unreadableImage(source.lastPathComponent)
        }
        CGImageDestinationAddImage(sink, cgImage, nil)
        guard CGImageDestinationFinalize(sink) else { throw LibraryError.unreadableImage(source.lastPathComponent) }
        return name
    }

    /// Names of the images in the textures folder.
    var textureNames: [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: texturesDirectory.path)) ?? [])
            .filter { $0.lowercased().hasSuffix(".png") }
            .sorted()
    }

    // MARK: - Files

    struct BrushFile: Codable {
        var format = BrushLibrary.formatVersion
        var brush: BrushDescriptor
    }

    enum LibraryError: LocalizedError {
        case newerFormat(Int)
        case unreadableImage(String)
        case notABrush(String)

        var errorDescription: String? {
            switch self {
            case .newerFormat(let version): return "This brush was made by a newer version of Artsy (format \(version))."
            case .unreadableImage(let name): return "\(name) could not be read as an image."
            case .notABrush(let name): return "\(name) is not a brush file."
            }
        }
    }

    private func url(for id: UUID) -> URL {
        directory.appendingPathComponent("\(id.uuidString).\(Self.fileExtension)")
    }

    private func load() {
        let files = ((try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.creationDateKey])) ?? [])
            .filter { $0.pathExtension == Self.fileExtension }
            .sorted { a, b in
                let da = (try? a.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantPast
                let db = (try? b.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantPast
                return da == db ? a.lastPathComponent < b.lastPathComponent : da < db
            }
        userBrushes = files.compactMap { file in
            guard let data = try? Data(contentsOf: file),
                  let decoded = try? JSONDecoder().decode(BrushFile.self, from: data) else {
                fputs("Artsy: could not read brush \(file.lastPathComponent)\n", stderr)
                return nil
            }
            return decoded.brush
        }
    }

    /// A name no brush has. With `copy`, the first free name is "<name> copy"; without, it
    /// is `name` itself if free.
    private func untakenName(basedOn name: String, copy: Bool = true) -> String {
        let taken = Set((all + [.eraser]).map(\.name))
        if !copy, !taken.contains(name) { return name }
        var candidate = name.hasSuffix(" copy") || name.range(of: #" copy \d+$"#, options: .regularExpression) != nil
            ? name : name + " copy"
        var counter = 2
        while taken.contains(candidate) {
            candidate = name.replacingOccurrences(of: #" copy( \d+)?$"#, with: "", options: .regularExpression) + " copy \(counter)"
            counter += 1
        }
        return candidate
    }
}

/// GIMP's `.gbr` brush file: a 28-byte header, a name, then grayscale or RGBA pixels.
/// Grayscale brushes are white where they paint.
enum GimpBrushFile {
    static func image(from data: Data) throws -> CGImage {
        func word(_ offset: Int) -> Int {
            data[offset..<offset + 4].reduce(0) { $0 << 8 | Int($1) }
        }
        guard data.count >= 28, data[20..<24] == Data("GIMP".utf8) else { throw BrushLibrary.LibraryError.notABrush("GIMP brush") }
        let headerSize = word(0), width = word(8), height = word(12), bytesPerPixel = word(16)
        guard width > 0, height > 0, [1, 4].contains(bytesPerPixel),
              data.count >= headerSize + width * height * bytesPerPixel else {
            throw BrushLibrary.LibraryError.notABrush("GIMP brush")
        }
        let pixels = data[headerSize..<headerSize + width * height * bytesPerPixel]
        let space = bytesPerPixel == 1 ? CGColorSpaceCreateDeviceGray() : CGColorSpaceCreateDeviceRGB()
        let info: CGBitmapInfo = bytesPerPixel == 1 ? [] : CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue)
        guard let provider = CGDataProvider(data: Data(pixels) as CFData),
              let image = CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: bytesPerPixel * 8,
                                  bytesPerRow: width * bytesPerPixel, space: space, bitmapInfo: info,
                                  provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent) else {
            throw BrushLibrary.LibraryError.notABrush("GIMP brush")
        }
        return image
    }
}
