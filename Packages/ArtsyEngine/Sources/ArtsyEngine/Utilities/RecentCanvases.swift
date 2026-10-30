import Foundation
import CoreGraphics
import ImageIO

/// The canvases opened lately, newest first, for the start screen and the Mac's Open
/// Recent: each by a bookmark, with its name, its size in pixels and when it was last
/// opened. Kept as JSON in Application Support, at most `limit` long. A bookmark is
/// resolved only when asked for, so a canvas that has moved or gone shows as missing
/// rather than failing the list; the path when last seen is kept for the name, and for
/// telling the same document again.
public final class RecentCanvases: ObservableObject {
    public struct Entry: Codable, Identifiable, Equatable {
        public var id: UUID
        /// The file's bookmark, security-scoped where the platform has such a thing.
        public var bookmark: Data?
        /// The path when last seen.
        public var path: String
        public var name: String
        public var width: Int
        public var height: Int
        public var openedAt: Date
    }

    public static let shared = RecentCanvases(fileURL: RecentCanvases.defaultFileURL())

    @Published public private(set) var entries: [Entry] = []
    public let limit: Int
    private let fileURL: URL?

    /// The list at `fileURL` (none: an in-memory list, for tests), at most `limit` long.
    public init(fileURL: URL?, limit: Int = 40) {
        self.fileURL = fileURL
        self.limit = limit
        if let fileURL, let data = try? Data(contentsOf: fileURL),
           let saved = try? JSONDecoder().decode([Entry].self, from: data) {
            entries = Array(saved.prefix(limit))
        }
    }

    public static func defaultFileURL() -> URL? {
        guard let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else { return nil }
        return support.appendingPathComponent("Artsy/recent-canvases.json")
    }

    /// The document at `url` was just opened, made or saved: to the front, with its name
    /// and size as they are now.
    public func note(_ url: URL, size: CGSize, at date: Date = Date()) {
        let url = url.standardizedFileURL
        var entry = Entry(id: UUID(), bookmark: Self.bookmark(of: url), path: url.path,
                          name: url.deletingPathExtension().lastPathComponent,
                          width: Int(size.width), height: Int(size.height), openedAt: date)
        // The same document by its path, or by its bookmark when the path has changed: iOS
        // moves the app's container when the app is updated
        if let index = entries.firstIndex(where: { $0.path == url.path })
            ?? entries.firstIndex(where: { self.url(of: $0)?.standardizedFileURL.path == url.path }) {
            entry.id = entries[index].id
            entries.remove(at: index)
        }
        entries.insert(entry, at: 0)
        if entries.count > limit { entries.removeLast(entries.count - limit) }
        save()
    }

    /// The document behind `entry` is now at `url`: renamed, or moved.
    public func moved(_ entry: Entry, to url: URL) {
        guard let index = entries.firstIndex(where: { $0.id == entry.id }) else { return }
        let url = url.standardizedFileURL
        entries[index].bookmark = Self.bookmark(of: url)
        entries[index].path = url.path
        entries[index].name = url.deletingPathExtension().lastPathComponent
        save()
    }

    public func remove(_ entry: Entry) {
        entries.removeAll { $0.id == entry.id }
        save()
    }

    public func removeAll() {
        entries = []
        save()
    }

    /// Where the document is now, if it still is: its bookmark resolved, else its path
    /// if a file is there. Nil once it has gone. Reads only, so a tile may ask from any
    /// thread; a moved document's entry is brought up to date when it is next opened.
    public func url(of entry: Entry) -> URL? {
        if let data = entry.bookmark {
            var stale = false
            if let url = try? URL(resolvingBookmarkData: data, options: Self.resolutionOptions, relativeTo: nil, bookmarkDataIsStale: &stale),
               FileManager.default.fileExists(atPath: url.path) || stale == false && url.startAccessingSecurityScopedResource() {
                if url.path != entry.path { url.stopAccessingSecurityScopedResource() }
                return url
            }
        }
        let url = URL(fileURLWithPath: entry.path)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    /// The thumbnail the document keeps, read now; nil for a document that has gone.
    public func thumbnail(of entry: Entry) -> CGImage? {
        guard let url = url(of: entry) else { return nil }
        return Self.thumbnail(in: url)
    }

    /// The `thumbnail.png` inside the package at `documentURL`: the canvas over white, at
    /// most 512 px a side, written on every save. Read whole and decoded here, while the
    /// document is reachable: an image left to decode when first drawn went back to the
    /// file after the security scope below had closed, and in the sandboxed App Store
    /// build that read is refused, so the start screen's tile came up empty.
    public static func thumbnail(in documentURL: URL) -> CGImage? {
        let scoped = documentURL.startAccessingSecurityScopedResource()
        defer { if scoped { documentURL.stopAccessingSecurityScopedResource() } }
        let file = documentURL.appendingPathComponent("thumbnail.png")
        guard let data = try? Data(contentsOf: file),
              let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(source, 0, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary)
    }

    // MARK: - Bookmarks and the file

    private static var creationOptions: URL.BookmarkCreationOptions {
        #if os(macOS)
        return [.withSecurityScope]
        #else
        return []
        #endif
    }

    private static var resolutionOptions: URL.BookmarkResolutionOptions {
        #if os(macOS)
        return [.withSecurityScope, .withoutUI]
        #else
        return [.withoutUI]
        #endif
    }

    private static func bookmark(of url: URL) -> Data? {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        return try? url.bookmarkData(options: creationOptions, includingResourceValuesForKeys: nil, relativeTo: nil)
    }

    private func save() {
        guard let fileURL else { return }
        do {
            try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(entries).write(to: fileURL, options: .atomic)
        } catch {
            fputs("Artsy: could not save the recent canvases: \(error.localizedDescription)\n", stderr)
        }
    }
}
