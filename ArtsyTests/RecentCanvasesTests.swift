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

    /// A package with a document.json and a square thumbnail of `size`, as a save leaves one.
    private func makeDocument(named name: String, thumbnail size: Int = 8) throws -> URL {
        let url = folder.appendingPathComponent("\(name).artsy")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: url.appendingPathComponent("document.json"))
        let context = try XCTUnwrap(CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
                                              space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(red: 0.8, green: 0.3, blue: 0.2, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: size, height: size))
        let image = try XCTUnwrap(context.makeImage())
        let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(
            url.appendingPathComponent("thumbnail.png") as CFURL, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        return url
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
    /// beside the size tiles' white swatches; with nothing, only the swatches.
    func testTheStartScreenComesUpWithTheListAndWithNothing() throws {
        let store = RecentCanvases(fileURL: nil)
        store.note(try makeDocument(named: "One"), size: CGSize(width: 1024, height: 768))
        let (reds, whites) = try render(StartView(recents: store, maxSide: 4096, actions: StartActions()), width: 860)
        XCTAssertGreaterThan(whites, 1000, "the size tiles' swatches: \(whites)")
        XCTAssertGreaterThan(reds, 1000, "the thumbnail, read from the package: \(reds)")
        let (noReds, phoneWhites) = try render(StartView(recents: RecentCanvases(fileURL: nil), maxSide: 4096, actions: StartActions()), width: 360)
        XCTAssertGreaterThan(phoneWhites, 500, "the phone's row of swatches: \(phoneWhites)")
        XCTAssertEqual(noReds, 0, "nothing in the list, nothing red")
    }

    /// The view on screen for a moment, then its pixels counted: those near white and
    /// those near the thumbnail's red.
    private func render(_ view: StartView, width: CGFloat) throws -> (reds: Int, whites: Int) {
        let host = NSHostingView(rootView: view)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: 640), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.orderFront(nil)
        defer { window.orderOut(nil); window.contentView = nil }
        // The thumbnails load off the main thread; give them a moment
        RunLoop.main.run(until: Date().addingTimeInterval(1.2))
        host.layoutSubtreeIfNeeded()
        window.displayIfNeeded()
        // The layer tree, images and all, into a bitmap at 1x
        let rep = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(host.bounds.width), pixelsHigh: Int(host.bounds.height),
                                                 bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                                 colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        let context = try XCTUnwrap(NSGraphicsContext(bitmapImageRep: rep))
        try XCTUnwrap(host.layer).render(in: context.cgContext)
        var reds = 0, whites = 0
        for y in stride(from: 0, to: rep.pixelsHigh, by: 2) {
            for x in stride(from: 0, to: rep.pixelsWide, by: 2) {
                guard let color = rep.colorAt(x: x, y: y) else { continue }
                let r = color.redComponent, g = color.greenComponent, b = color.blueComponent
                if r > 0.85 && g > 0.85 && b > 0.85 { whites += 1 }
                if r > 0.6 && g < 0.4 && b < 0.35 { reds += 1 }
            }
        }
        return (reds, whites)
    }
}
