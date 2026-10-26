import AppKit
import CryptoKit
import ImageIO
import UniformTypeIdentifiers
import ArtsyEngine

/// Stroke previews, one per brush, for the bar and the brush panel: the brush's stroke in
/// white with its transparency, 180 by 60, for a dark ground. A tile is rendered the first
/// time its brush is asked for and again once the brush has been edited. Rendered tiles
/// are kept on disk as well, each named by a digest of the brush's settings and the app's
/// build, so the next launch finds them ready and a build that paints differently renders
/// them afresh. The folder is in Caches, which the system may empty at any time.
final class BrushPreviewCache {
    static let size = CGSize(width: 180, height: 60)
    /// Raised when the tile itself changes (its colour, its stroke's size) while the
    /// brushes and the build do not.
    static let tileVersion = 1

    private let renderer: BrushPreview?
    private let directory: URL?
    private let build: String
    private var rendered: [UUID: (brush: BrushDescriptor, image: NSImage)] = [:]

    /// `directory` keeps the tiles between launches; nil keeps them for this run only.
    init(renderer: BrushPreview?, directory: URL? = BrushPreviewCache.defaultDirectory, build: String = BrushPreviewCache.appBuild) {
        self.renderer = renderer
        self.directory = directory
        self.build = build
    }

    /// `~/Library/Caches/<bundle>/Brush Previews`.
    static var defaultDirectory: URL? {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first?
            .appendingPathComponent(Bundle.main.bundleIdentifier ?? "Artsy", isDirectory: true)
            .appendingPathComponent("Brush Previews", isDirectory: true)
    }

    /// The build number, which every release raises.
    static var appBuild: String {
        Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "0"
    }

    func image(for brush: BrushDescriptor) -> NSImage? {
        if let hit = rendered[brush.id], hit.brush == brush { return hit.image }
        let file = self.file(for: brush)
        if let file, let kept = Self.read(file) {
            let image = NSImage(cgImage: kept, size: Self.size)
            rendered[brush.id] = (brush, image)
            return image
        }
        guard let renderer,
              let cg = renderer.render(brush: brush, color: StrokeColor(red: 1, green: 1, blue: 1, alpha: 1), size: 16, onPaper: false)
        else { return nil }
        let image = NSImage(cgImage: cg, size: Self.size)
        rendered[brush.id] = (brush, image)
        if let file { Self.write(cg, to: file) }
        return image
    }

    /// Readies the tiles of `brushes`, one between each turn of the run loop from `delay`
    /// on, so the panel's first open finds them there, and then drops the tiles no brush
    /// of theirs uses any more: other builds', edited brushes'. While `paused` says so (a
    /// stroke is down) it waits.
    func warm(_ brushes: [BrushDescriptor], after delay: TimeInterval = 1, paused: @escaping () -> Bool = { false }) {
        var remaining = brushes[...]
        func step() {
            guard let brush = remaining.first else { prune(keeping: brushes); return }
            if paused() {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: step)
                return
            }
            remaining.removeFirst()
            _ = image(for: brush)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.02, execute: step)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: step)
    }

    /// The tile's file, named by a digest of the brush's settings (all of them, as they are
    /// saved), the tile's own parameters and the build.
    private func file(for brush: BrushDescriptor) -> URL? {
        guard let directory else { return nil }
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        guard let settings = try? encoder.encode(brush) else { return nil }
        var digest = SHA256()
        digest.update(data: Data("build \(build) tile \(Self.tileVersion) \(Int(Self.size.width))x\(Int(Self.size.height))\n".utf8))
        digest.update(data: settings)
        let name = digest.finalize().map { String(format: "%02x", $0) }.joined()
        return directory.appendingPathComponent("\(name).png")
    }

    private func prune(keeping brushes: [BrushDescriptor]) {
        guard let directory else { return }
        let current = Set(brushes.compactMap { file(for: $0)?.lastPathComponent })
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        for name in names where name.hasSuffix(".png") && !current.contains(name) {
            try? FileManager.default.removeItem(at: directory.appendingPathComponent(name))
        }
    }

    private static func read(_ file: URL) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(file as CFURL, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(source, 0, nil)
    }

    private static func write(_ image: CGImage, to file: URL) {
        try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard let destination = CGImageDestinationCreateWithURL(file as CFURL, UTType.png.identifier as CFString, 1, nil) else { return }
        CGImageDestinationAddImage(destination, image, nil)
        CGImageDestinationFinalize(destination)
    }
}
