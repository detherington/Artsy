import XCTest
import SwiftUI
import ImageIO
import UniformTypeIdentifiers
@testable import Artsy
@testable import ArtsyEngine

/// The list behind the start screen: newest first, one entry a document, capped,
/// surviving a relaunch, a document that has gone saying so, its thumbnail read; and
/// the screen itself coming up with the list, and with nothing.
final class RecentCanvasesTests: XCTestCase {
    private var folder: URL!

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("RecentCanvasesTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: folder)
    }

    private static let red = CGColor(red: 0.8, green: 0.3, blue: 0.2, alpha: 1)
    private static let blue = CGColor(red: 0.1, green: 0.1, blue: 0.9, alpha: 1)

    /// A package with a document.json and a square thumbnail of `size`, as a save leaves one.
    private func makeDocument(named name: String, thumbnail size: Int = 8) throws -> URL {
        let url = folder.appendingPathComponent("\(name).artsy")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: url.appendingPathComponent("document.json"))
        try writeThumbnail(into: url, size: size, color: Self.red)
        return url
    }

    /// The package's thumbnail.png, a square of `color`, as a save rewrites it.
    private func writeThumbnail(into url: URL, size: Int = 8, color: CGColor) throws {
        let context = try XCTUnwrap(CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
                                              space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(color)
        context.fill(CGRect(x: 0, y: 0, width: size, height: size))
        let image = try XCTUnwrap(context.makeImage())
        let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(
            url.appendingPathComponent("thumbnail.png") as CFURL, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
    }

    func testADocumentWhoseFolderMovedIsStillOneEntry() throws {
        // iOS moves the app's container when the app is updated: the document's path changes
        // under it, and the bookmark still finds it
        let home = folder.appendingPathComponent("Container A/Documents", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        let before = home.appendingPathComponent("Moved.artsy")
        try FileManager.default.createDirectory(at: before, withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: before.appendingPathComponent("document.json"))
        let recents = RecentCanvases(fileURL: folder.appendingPathComponent("recent.json"))
        recents.note(before, size: CGSize(width: 10, height: 10))
        let movedHome = folder.appendingPathComponent("Container B/Documents", isDirectory: true)
        try FileManager.default.createDirectory(at: movedHome.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.moveItem(at: home, to: movedHome)
        let after = movedHome.appendingPathComponent("Moved.artsy")
        recents.note(after, size: CGSize(width: 10, height: 10))
        XCTAssertEqual(recents.entries.count, 1, "the same document, found by its bookmark")
        XCTAssertEqual(recents.entries[0].path, after.standardizedFileURL.path)
    }

    func testNewestFirstOneADocumentAndCapped() throws {
        let store = RecentCanvases(fileURL: nil, limit: 3)
        let a = try makeDocument(named: "A"), b = try makeDocument(named: "B")
        let c = try makeDocument(named: "C"), d = try makeDocument(named: "D")
        store.note(a, size: CGSize(width: 10, height: 20))
        store.note(b, size: CGSize(width: 30, height: 40))
        XCTAssertEqual(store.entries.map(\.name), ["B", "A"])
        XCTAssertEqual(store.entries[1].width, 10)
        XCTAssertEqual(store.entries[1].height, 20)
        let idOfA = store.entries[1].id
        store.note(a, size: CGSize(width: 10, height: 20))
        XCTAssertEqual(store.entries.map(\.name), ["A", "B"], "opened again: to the front, not twice")
        XCTAssertEqual(store.entries[0].id, idOfA, "the same entry")
        store.note(c, size: .zero)
        store.note(d, size: .zero)
        XCTAssertEqual(store.entries.map(\.name), ["D", "C", "A"], "capped at three")
        store.remove(store.entries[1])
        XCTAssertEqual(store.entries.map(\.name), ["D", "A"])
        store.removeAll()
        XCTAssertTrue(store.entries.isEmpty)
    }

    func testTheListSurvivesARelaunchAndAGoneDocumentSaysSo() throws {
        let file = folder.appendingPathComponent("recent.json")
        let harbour = try makeDocument(named: "Harbour")
        let gone = try makeDocument(named: "Gone")
        RecentCanvases(fileURL: file, limit: 10).note(harbour, size: CGSize(width: 2048, height: 2048))
        let store = RecentCanvases(fileURL: file, limit: 10)
        XCTAssertEqual(store.entries.map(\.name), ["Harbour"], "read back")
        store.note(gone, size: .zero)
        try FileManager.default.removeItem(at: gone)
        let again = RecentCanvases(fileURL: file, limit: 10)
        XCTAssertEqual(again.entries.map(\.name), ["Gone", "Harbour"])
        XCTAssertNil(again.url(of: again.entries[0]), "deleted: nowhere")
        XCTAssertNil(again.thumbnail(of: again.entries[0]))
        XCTAssertEqual(again.url(of: again.entries[1])?.standardizedFileURL.path, harbour.standardizedFileURL.path)
        let thumbnail = try XCTUnwrap(again.thumbnail(of: again.entries[1]))
        XCTAssertEqual(thumbnail.width, 8)
        XCTAssertEqual(again.entries[1].width, 2048)
    }

    func testARenamedDocumentKeepsItsPlace() throws {
        let store = RecentCanvases(fileURL: nil)
        let before = try makeDocument(named: "Before")
        store.note(before, size: .zero)
        let after = folder.appendingPathComponent("After.artsy")
        try FileManager.default.moveItem(at: before, to: after)
        store.moved(store.entries[0], to: after)
        XCTAssertEqual(store.entries.map(\.name), ["After"])
        XCTAssertEqual(store.url(of: store.entries[0])?.standardizedFileURL.path, after.standardizedFileURL.path)
    }

    /// The screen drawn: with a canvas in the list, its red thumbnail is on the screen
    /// (on the Continue card, large) beside the size pills' white glyphs and the words;
    /// with nothing, only those.
    func testTheStartScreenComesUpWithTheListAndWithNothing() throws {
        let store = RecentCanvases(fileURL: nil)
        store.note(try makeDocument(named: "One"), size: CGSize(width: 1024, height: 768))
        let shown = try show(StartView(recents: store, maxSide: 4096, actions: StartActions()), width: 860)
        defer { shown.close() }
        let first = try shown.count()
        XCTAssertGreaterThan(first.whites, 150, "the size pills' glyphs and the words: \(first.whites)")
        XCTAssertGreaterThan(first.reds, 1000, "the thumbnail, read from the package, on the card: \(first.reds)")
        let empty = try show(StartView(recents: RecentCanvases(fileURL: nil), maxSide: 4096, actions: StartActions()), width: 360)
        defer { empty.close() }
        let nothing = try empty.count()
        XCTAssertGreaterThan(nothing.whites, 150, "the phone's row of pills and the words: \(nothing.whites)")
        XCTAssertEqual(nothing.reds, 0, "nothing in the list, nothing red")
    }

    /// A save while the screen is up (the Mac's Window ▸ Start beside a canvas) notes the
    /// document anew, and its tile reads the thumbnail again: the drawing shown is the
    /// one just saved, not the one from when the screen came up.
    func testATileFollowsASaveWhileTheScreenIsUp() throws {
        let store = RecentCanvases(fileURL: nil)
        let document = try makeDocument(named: "Live")
        store.note(document, size: CGSize(width: 1024, height: 768))
        let shown = try show(StartView(recents: store, maxSide: 4096, actions: StartActions()), width: 860)
        defer { shown.close() }
        let before = try shown.count()
        XCTAssertGreaterThan(before.reds, 1000, "the thumbnail as saved first: \(before.reds)")
        XCTAssertEqual(before.blues, 0)
        try writeThumbnail(into: document, color: Self.blue)
        store.note(document, size: CGSize(width: 1024, height: 768), at: Date().addingTimeInterval(1))
        let after = try shown.count()
        XCTAssertGreaterThan(after.blues, 1000, "the thumbnail as saved again: \(after.blues)")
        XCTAssertEqual(after.reds, 0, "and not the old one: \(after.reds)")
    }

    /// "Full screen" is the device's own pixels, offered after the size used last and
    /// before the presets, the way the screen is turned; and in the last size's place
    /// when that was the screen's.
    func testTheStartScreenOffersFullScreenAtThisScreensPixels() {
        let last = CGSize(width: 2048, height: 2048)
        let sizes = StartView.sizes(last: last, screen: CGSize(width: 2752, height: 2064), maxSide: 4096)
        XCTAssertEqual(sizes.map(\.name).prefix(3), ["Same as last", "Full screen", "Small"])
        XCTAssertEqual(sizes[1].id, "screen")
        XCTAssertEqual(sizes[1].width, 2752)
        XCTAssertEqual(sizes[1].height, 2064)
        XCTAssertFalse(sizes.contains { $0.name == "Medium" }, "the preset that is the last size is not repeated")
        XCTAssertFalse(sizes.contains { $0.name == "Huge" }, "nor one the device cannot take")

        let turned = StartView.sizes(last: last, screen: CGSize(width: 2064, height: 2752), maxSide: 4096)
        XCTAssertEqual(turned[1].width, 2064, "the screen the way it is held")
        XCTAssertNil(StartView.sizes(last: last, screen: nil, maxSide: 4096).first { $0.id == "screen" })
        XCTAssertNil(StartView.sizes(last: last, screen: CGSize(width: 6144, height: 3456), maxSide: 4096).first { $0.id == "screen" },
                     "a screen with more pixels than the device takes as a canvas")
        let afterFullScreen = StartView.sizes(last: CGSize(width: 2752, height: 2064), screen: CGSize(width: 2752, height: 2064), maxSide: 4096)
        XCTAssertEqual(afterFullScreen.first?.name, "Full screen", "the last canvas was the screen's: Full screen stands in its place")
        XCTAssertNil(afterFullScreen.first { $0.id == "last" })
        XCTAssertEqual(afterFullScreen[1].name, "Small")
        let afterAHuge = StartView.sizes(last: CGSize(width: 8192, height: 8192), screen: nil, maxSide: 4096)
        XCTAssertNil(afterAHuge.first { $0.id == "last" }, "a last size the device cannot take is not offered again")
        XCTAssertEqual(afterAHuge.first?.name, "Small")
    }

    /// The view in a window on screen, to be counted as often as wanted and closed.
    private func show(_ view: StartView, width: CGFloat) throws -> ShownView {
        let host = NSHostingView(rootView: view)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: 640), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.orderFront(nil)
        return ShownView(window: window, host: host)
    }

    private struct ShownView {
        let window: NSWindow
        let host: NSHostingView<StartView>

        /// A moment for the thumbnails, which load off the main thread, then the pixels
        /// counted: those near white, those near the red thumbnail, those near the blue.
        func count() throws -> (reds: Int, whites: Int, blues: Int) {
            RunLoop.main.run(until: Date().addingTimeInterval(1.2))
            host.layoutSubtreeIfNeeded()
            window.displayIfNeeded()
            // The layer tree, images and all, into a bitmap at 1x
            let rep = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(host.bounds.width), pixelsHigh: Int(host.bounds.height),
                                                     bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                                     colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
            let context = try XCTUnwrap(NSGraphicsContext(bitmapImageRep: rep))
            try XCTUnwrap(host.layer).render(in: context.cgContext)
            var reds = 0, whites = 0, blues = 0
            for y in stride(from: 0, to: rep.pixelsHigh, by: 2) {
                for x in stride(from: 0, to: rep.pixelsWide, by: 2) {
                    guard let color = rep.colorAt(x: x, y: y) else { continue }
                    let r = color.redComponent, g = color.greenComponent, b = color.blueComponent
                    if r > 0.85 && g > 0.85 && b > 0.85 { whites += 1 }
                    if r > 0.6 && g < 0.4 && b < 0.35 { reds += 1 }
                    if b > 0.7 && r < 0.3 && g < 0.3 { blues += 1 }
                }
            }
            return (reds, whites, blues)
        }

        func close() {
            window.orderOut(nil)
            window.contentView = nil
        }
    }
}
