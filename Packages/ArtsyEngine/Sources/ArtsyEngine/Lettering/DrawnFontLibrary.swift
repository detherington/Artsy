import Combine
import CoreText
import Foundation

/// Drawn and imported fonts ready to set words in, by id and style: what `BalloonLayout`
/// reads. Filled by `DrawnFontLibrary` as it compiles its fonts, from any thread. It also
/// knows which characters of a drawn font have other versions, to rotate repeats through
/// them (`vary`).
public enum DrawnFonts {
    private static let lock = NSLock()
    private static var descriptors: [UUID: [DrawnFontStyle: CTFontDescriptor]] = [:]
    private static var varieties: [UUID: Variety] = [:]

    /// What a drawn font sets each character in, and in how many versions.
    struct Variety {
        var setting: [Character: Character]
        var versions: [Character: Int]
    }

    /// Makes `data`, a font file, the `style` member set for `id`. False if Core Text cannot
    /// read it.
    @discardableResult
    public static func register(_ data: Data, for id: UUID, style: DrawnFontStyle = .regular) -> Bool {
        guard let descriptor = CTFontManagerCreateFontDescriptorFromData(data as CFData) else { return false }
        lock.lock()
        descriptors[id, default: [:]][style] = descriptor
        lock.unlock()
        // Words set in it may ink differently now
        BalloonMargins.forget()
        return true
    }

    /// Records which characters of `font` have other versions; none for an imported font.
    static func noteVersions(of font: DrawnFont) {
        var setting: [Character: Character] = [:], versions: [Character: Int] = [:]
        if font.isDrawn {
            for character in DrawnFont.characters {
                let set = font.setting(character)
                let count = font.versions(of: set)
                guard count > 1 else { continue }
                setting[character] = set
                versions[set] = count
            }
        }
        lock.lock()
        varieties[font.id] = Variety(setting: setting, versions: versions)
        lock.unlock()
    }

    public static func unregister(_ id: UUID) {
        lock.lock()
        descriptors[id] = nil
        varieties[id] = nil
        lock.unlock()
        BalloonMargins.forget()
    }

    public static func isRegistered(_ id: UUID, style: DrawnFontStyle = .regular) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return descriptors[id]?[style] != nil
    }

    /// The `style` member of the font for `id` at `size`, characters it lacks set in the font
    /// named `fallback`; nil if no such member is registered.
    public static func font(id: UUID, size: CGFloat, style: DrawnFontStyle = .regular, fallback: String? = nil) -> CTFont? {
        lock.lock()
        let found = descriptors[id]?[style]
        lock.unlock()
        guard var descriptor = found else { return nil }
        if let fallback {
            let cascade = [CTFontDescriptorCreateWithNameAndSize(fallback as CFString, 0)] as CFArray
            descriptor = CTFontDescriptorCreateCopyWithAttributes(
                descriptor, [kCTFontCascadeListAttribute: cascade] as CFDictionary)
        }
        return CTFontCreateWithFontDescriptor(descriptor, size, nil)
    }

    /// `text` with each repeat of a character the font has other versions of set in its next
    /// version, round and round: the first A as drawn first, the second in its second
    /// version, the third in its third or its first again. Counted through the whole text, so
    /// a balloon's letters never repeat one another exactly; the same text varies the same.
    public static func vary(_ text: String, font id: UUID) -> String {
        lock.lock()
        let variety = varieties[id]
        lock.unlock()
        guard let variety, !variety.versions.isEmpty else { return text }
        var seen: [Character: Int] = [:]
        var out = String.UnicodeScalarView()
        for character in text {
            guard let set = variety.setting[character], let count = variety.versions[set] else {
                out.append(contentsOf: character.unicodeScalars)
                continue
            }
            let version = seen[set, default: 0] % count
            seen[set, default: 0] += 1
            if version > 0, let scalar = DrawnFont.alternateScalar(for: set, version: version) {
                out.append(scalar)
            } else {
                out.append(contentsOf: character.unicodeScalars)
            }
        }
        return String(out)
    }
}

/// The artist's lettering fonts: each a `.artsyfont` file (the font as drawn, or a font file
/// imported, JSON) in Application Support/Artsy/Fonts, a drawn one's compiled family beside
/// it (`<id>.ttf`, `<id>-bold.ttf`, `<id>-italic.ttf`, `<id>-boldItalic.ttf`). A change is
/// saved and compiled off the main thread, the outlines of glyphs that did not change kept
/// from the last time; the compiled files are registered with `DrawnFonts`, and
/// `fontsDidChange` tells the open canvases which fonts to set their balloons in again.
public final class DrawnFontLibrary: ObservableObject {
    /// The library the app uses; tests put one of their own in its place.
    public static var shared = DrawnFontLibrary(directory: defaultDirectory)

    public static let fileExtension = "artsyfont"
    /// Posted on the main queue when fonts set words differently: changed, deleted, or come
    /// with a document in a version other than the library's. `userInfo["ids"]` is a
    /// `Set<UUID>` of them.
    public static let fontsDidChange = Notification.Name("DrawnFontLibrary.fontsDidChange")

    public static var defaultDirectory: URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return support.appendingPathComponent("Artsy/Fonts", isDirectory: true)
    }

    public let directory: URL
    /// The fonts, by name.
    @Published public private(set) var fonts: [DrawnFont] = []
    /// Counts each font compiled, for whatever shows words set in them.
    @Published public private(set) var revision = 0

    private let queue = DispatchQueue(label: "com.artsy.drawn-fonts", qos: .userInitiated)
    private let pendingLock = NSLock()
    /// Fonts waiting to be compiled, the latest of each, and whether to save and to say so.
    private var pending: [UUID: (font: DrawnFont, save: Bool, announce: Bool)] = [:]

    /// A glyph traced at a weight.
    private struct Traced: Hashable {
        let glyph: DrawnFontFile.GlyphKey
        let weight: CGFloat
    }
    /// Each font's traced glyphs, with the glyph each was traced from; touched only on the queue.
    private var outlines: [UUID: [Traced: (glyph: DrawnGlyph, contours: [GlyphOutline.Contour])]] = [:]

    public init(directory: URL) {
        self.directory = directory
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        load()
    }

    private func fileURL(_ id: UUID) -> URL { directory.appendingPathComponent("\(id.uuidString).\(Self.fileExtension)") }
    private func compiledURL(_ id: UUID, _ style: DrawnFontStyle) -> URL {
        directory.appendingPathComponent(style == .regular ? "\(id.uuidString).ttf" : "\(id.uuidString)-\(style.rawValue).ttf")
    }

    /// Every font on disk: an imported one registered from its file, a drawn one from its
    /// compiled family when that is as new as the font, else compiled again.
    private func load() {
        let fm = FileManager.default
        let files = (try? fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        var loaded: [DrawnFont] = []
        let written = { (u: URL) in (try? u.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate }
        for url in files where url.pathExtension == Self.fileExtension {
            guard let data = try? Data(contentsOf: url), let font = try? JSONDecoder().decode(DrawnFont.self, from: data) else {
                DiagnosticsLog.shared.note(.app, "could not read the lettering font \(url.lastPathComponent)")
                continue
            }
            loaded.append(font)
            if let imported = font.imported {
                DrawnFonts.register(imported.data, for: font.id)
                DrawnFonts.noteVersions(of: font)
                continue
            }
            let fresh = DrawnFontStyle.allCases.allSatisfy { style in
                let compiled = compiledURL(font.id, style)
                guard let made = written(compiled), let drawn = written(url), made >= drawn,
                      let ttf = try? Data(contentsOf: compiled) else { return false }
                return DrawnFonts.register(ttf, for: font.id, style: style)
            }
            if fresh {
                DrawnFonts.noteVersions(of: font)
            } else {
                compile(font, save: false, announce: false)
            }
        }
        fonts = loaded.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    // MARK: - Fonts

    public func font(id: UUID?) -> DrawnFont? {
        guard let id else { return nil }
        return fonts.first { $0.id == id }
    }

    /// A new font with nothing drawn, saved.
    @discardableResult
    public func newFont(named name: String? = nil) -> DrawnFont {
        let font = DrawnFont(name: name ?? DrawnFont.newName(among: fonts))
        insert(font)
        compile(font, save: true, announce: false)
        return font
    }

    /// `font` in place of the one with its id, saved and compiled again.
    public func update(_ font: DrawnFont) {
        guard let index = fonts.firstIndex(where: { $0.id == font.id }) else { return }
        // A new name sets no balloon differently; anything drawn, spaced or kerned does
        var unnamed = fonts[index], other = font
        unnamed.name = ""; other.name = ""; unnamed.modified = .distantPast; other.modified = .distantPast
        let reshapes = unnamed != other
        var changed = font
        changed.modified = Date()
        fonts[index] = changed
        fonts.sort { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        compile(changed, save: true, announce: reshapes)
    }

    /// A copy of the font with `id`, named for it, saved.
    @discardableResult
    public func duplicate(_ id: UUID) -> DrawnFont? {
        guard let original = font(id: id) else { return nil }
        var copy = original
        copy.id = UUID()
        copy.name = DrawnFont.newName(among: fonts, base: "\(original.name) copy")
        insert(copy)
        compile(copy, save: true, announce: false)
        return copy
    }

    /// Takes the font with `id` out of the library and off the disk. Balloons set in it go
    /// back to their face.
    public func delete(_ id: UUID) {
        guard fonts.contains(where: { $0.id == id }) else { return }
        fonts.removeAll { $0.id == id }
        pendingLock.lock()
        pending[id] = nil
        pendingLock.unlock()
        let files = [fileURL(id)] + DrawnFontStyle.allCases.map { compiledURL(id, $0) }
        queue.async { [weak self] in
            self?.outlines[id] = nil
            for file in files { try? FileManager.default.removeItem(at: file) }
            DrawnFonts.unregister(id)
            DispatchQueue.main.async { self?.announce([id]) }
        }
    }

    /// Fonts a document brought: those the library lacks join it; for those it has, the
    /// library's stand, and canvases are told to set those that differ again.
    public func adopt(_ brought: [DrawnFont]) {
        var differing: Set<UUID> = []
        for font in brought {
            if let mine = self.font(id: font.id) {
                if mine.glyphs != font.glyphs || mine.alternates != font.alternates || mine.spacing != font.spacing
                    || mine.kerning != font.kerning || mine.imported != font.imported {
                    differing.insert(font.id)
                }
            } else {
                insert(font)
                compile(font, save: true, announce: false)
            }
        }
        guard !differing.isEmpty else { return }
        // Once anything queued for them is compiled
        queue.async { DispatchQueue.main.async { [weak self] in self?.announce(differing) } }
    }

    /// A font file brought in: one Artsy exported comes back as drawn, to be drawn on again
    /// (as itself if the library has it no longer, else as a copy); any other is set as it is.
    @discardableResult
    public func importFont(_ data: Data) throws -> DrawnFont {
        var font = try DrawnFontFile.importing(data)
        if let mine = self.font(id: font.id) {
            if mine.glyphs == font.glyphs, mine.alternates == font.alternates, mine.kerning == font.kerning { return mine }
            font.id = UUID()
        }
        font.name = DrawnFont.newName(among: fonts, base: font.name)
        font.modified = Date()
        insert(font)
        compile(font, save: true, announce: false)
        return font
    }

    /// The fonts with these ids that the library has.
    public func fonts(withIDs ids: Set<UUID>) -> [DrawnFont] {
        fonts.filter { ids.contains($0.id) }
    }

    /// The `style` member of a drawn font as a TrueType file named for itself, to export;
    /// nil if nothing is drawn or the font was imported.
    public func exportedFile(for id: UUID, style: DrawnFontStyle = .regular) -> Data? {
        guard let font = font(id: id), font.isDrawn else { return nil }
        return queue.sync {
            DrawnFontFile.trueType(for: font, style: style, outlines: traced(font, weight: style.isBold ? font.boldness : 1),
                                   forExport: true)
        }
    }

    /// The whole family of a drawn font as files named for themselves, regular first.
    public func exportedFamily(for id: UUID) -> [(name: String, data: Data)] {
        guard let font = font(id: id) else { return [] }
        return DrawnFontStyle.allCases.compactMap { style in
            exportedFile(for: id, style: style).map { (DrawnFontFile.fileName(of: font, style: style), $0) }
        }
    }

    /// Returns once every change so far is compiled and registered.
    public func waitUntilCompiled() {
        queue.sync {}
    }

    private func insert(_ font: DrawnFont) {
        fonts.append(font)
        fonts.sort { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    // MARK: - Compiling

    private func compile(_ font: DrawnFont, save: Bool, announce: Bool) {
        pendingLock.lock()
        let earlier = pending[font.id]
        pending[font.id] = (font, save || earlier?.save == true, announce || earlier?.announce == true)
        pendingLock.unlock()
        let file = fileURL(font.id)
        queue.async { [weak self] in
            guard let self else { return }
            self.pendingLock.lock()
            let job = self.pending.removeValue(forKey: font.id)
            self.pendingLock.unlock()
            guard let job else { return } // compiled already with a later change, or deleted
            let font = job.font
            if job.save {
                do {
                    let encoder = JSONEncoder()
                    encoder.outputFormatting = [.sortedKeys]
                    try encoder.encode(font).write(to: file, options: .atomic)
                } catch {
                    DiagnosticsLog.shared.error(error, doing: "saving the font \(font.name)")
                }
            }
            DrawnFonts.unregister(font.id)
            if let imported = font.imported {
                DrawnFonts.register(imported.data, for: font.id)
            } else {
                let regular = self.traced(font, weight: 1), bold = self.traced(font, weight: font.boldness)
                for style in DrawnFontStyle.allCases {
                    let compiled = self.compiledURL(font.id, style)
                    if let data = DrawnFontFile.trueType(for: font, style: style, outlines: style.isBold ? bold : regular),
                       DrawnFonts.register(data, for: font.id, style: style) {
                        try? data.write(to: compiled, options: .atomic)
                    } else {
                        try? FileManager.default.removeItem(at: compiled)
                    }
                }
            }
            DrawnFonts.noteVersions(of: font)
            DispatchQueue.main.async {
                self.revision += 1
                if job.announce { self.announce([font.id]) }
            }
        }
    }

    /// The clean outlines of every glyph drawn in `font` at `weight` (1 for the drawing, the
    /// boldness for the bold), traced again only where the glyph changed. On the queue.
    private func traced(_ font: DrawnFont, weight: CGFloat) -> DrawnFontFile.Outlines {
        var kept = outlines[font.id] ?? [:]
        var result: DrawnFontFile.Outlines = [:]
        var used: Set<Traced> = []
        for character in DrawnFont.characters {
            for version in 0..<font.versions(of: character) {
                guard let glyph = font.glyph(for: character, version: version) else { continue }
                let key = Traced(glyph: DrawnFontFile.GlyphKey(character, version), weight: weight)
                used.insert(key)
                if let cached = kept[key], cached.glyph == glyph {
                    result[key.glyph] = cached.contours
                } else {
                    let contours = GlyphOutline.contours(of: weight == 1 ? glyph : glyph.emboldened(by: weight))
                    kept[key] = (glyph, contours)
                    result[key.glyph] = contours
                }
            }
        }
        // Forget what is no longer drawn at this weight, and other weights of the bold
        outlines[font.id] = kept.filter { used.contains($0.key) || ($0.key.weight != weight && ($0.key.weight == 1) != (weight == 1)) }
        return result
    }

    private func announce(_ ids: Set<UUID>) {
        NotificationCenter.default.post(name: Self.fontsDidChange, object: self, userInfo: ["ids": ids])
    }
}
