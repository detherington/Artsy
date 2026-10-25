import XCTest
import SwiftUI
import AppKit
@testable import Artsy

final class BrushStudioTests: XCTestCase {
    private var directory: URL!
    private var library: BrushLibrary!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ArtsyBrushStudioTests-\(UUID().uuidString)", isDirectory: true)
        library = BrushLibrary(directory: directory)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    /// The first change to a built-in brush lands on a copy, which the canvas switches to.
    func testChangingABuiltInBrushMakesACopy() throws {
        let harness = try EngineHarness(width: 64, height: 64)
        harness.select(.pencil)
        let model = BrushStudioModel(viewModel: harness.viewModel, library: library, previewRenderer: nil)
        XCTAssertTrue(model.isBuiltIn)

        model.apply { $0.hardness = 0.9 }
        XCTAssertFalse(model.isBuiltIn)
        XCTAssertEqual(model.brush.name, "Pencil copy")
        XCTAssertEqual(model.brush.hardness, 0.9)
        XCTAssertEqual(harness.viewModel.currentBrush, model.brush, "the canvas draws with the copy from now on")
        XCTAssertEqual(library.userBrushes, [model.brush], "and it is saved")
        XCTAssertEqual(BrushDescriptor.pencil.hardness, 0.55, "the built-in is untouched")

        model.apply { $0.baseSize = 30 }
        XCTAssertEqual(library.userBrushes.count, 1, "later changes go to the same copy")
        XCTAssertEqual(library.userBrushes[0].baseSize, 30)
    }

    func testBindingsReachNestedSettings() throws {
        let harness = try EngineHarness(width: 64, height: 64)
        harness.select(.chalk)
        let model = BrushStudioModel(viewModel: harness.viewModel, library: library, previewRenderer: nil)

        model.stampBinding(\.spacing, default: 0).wrappedValue = 0.33
        XCTAssertEqual(model.stampSettings?.spacing, 0.33)
        model.stampBinding(\.grain, default: nil).wrappedValue = nil
        XCTAssertNil(model.stampSettings?.grain)
        model.binding(\.pressureDynamics.sizeMin).wrappedValue = 0.1
        XCTAssertEqual(model.brush.pressureDynamics.sizeMin, 0.1)

        model.setRendersWithDabs(false)
        XCTAssertEqual(model.brush.rendering, .ribbon(.procedural))
        XCTAssertNil(model.stampSettings)
        model.stampBinding(\.flow, default: 0).wrappedValue = 0.2   // no stamp settings: nothing to change
        XCTAssertNil(model.stampSettings)
        model.setRendersWithDabs(true)
        XCTAssertEqual(model.stampSettings?.spacing, 0.1, "back to dabs with fresh defaults")
    }

    func testPickingAnotherBrushBringsItIntoTheStudio() throws {
        let harness = try EngineHarness(width: 64, height: 64)
        harness.select(.pencil)
        let model = BrushStudioModel(viewModel: harness.viewModel, library: library, previewRenderer: nil)
        harness.viewModel.currentBrush = .oil
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        XCTAssertEqual(model.brush, .oil)
        XCTAssertTrue(model.isBuiltIn)
    }

    func testPreviewRendersTheBrush() throws {
        let preview = try BrushPreview(context: EngineHarness.sharedContext)
        let image = try XCTUnwrap(preview.render(brush: .inkBrush, color: .black, size: 16))
        XCTAssertEqual(image.width, 360)
        let bitmap = NSBitmapImageRep(cgImage: image)
        var dark = 0
        for x in stride(from: 0, to: 360, by: 4) {
            for y in stride(from: 0, to: 150, by: 4) where (bitmap.colorAt(x: x, y: y)?.redComponent ?? 1) < 0.5 { dark += 1 }
        }
        XCTAssertGreaterThan(dark, 40, "the stroke is there")
        XCTAssertLessThan(dark, 1500, "and it isn't everything")

        let faint = try XCTUnwrap(preview.render(brush: .airbrush, color: .black, size: 40))
        XCTAssertNotNil(faint)
    }

    /// The bar and the brush panel show the stroke alone, white on their dark grey: no
    /// paper, and the image keeps its transparency. With ARTSY_DUMP_UI=1 it is written out.
    func testPreviewWithoutPaperKeepsTheStrokesTransparency() throws {
        let preview = try BrushPreview(context: EngineHarness.sharedContext, size: BrushPreviewCache.size)
        let white = StrokeColor(red: 1, green: 1, blue: 1, alpha: 1)
        let image = try XCTUnwrap(preview.render(brush: .inkBrush, color: white, size: 16, onPaper: false))
        let bitmap = NSBitmapImageRep(cgImage: image)
        var painted = 0, clear = 0
        for x in stride(from: 0, to: image.width, by: 2) {
            for y in stride(from: 0, to: image.height, by: 2) {
                let alpha = bitmap.colorAt(x: x, y: y)?.alphaComponent ?? 0
                if alpha > 0.5 { painted += 1 } else if alpha == 0 { clear += 1 }
            }
        }
        XCTAssertGreaterThan(painted, 100, "the stroke is there")
        XCTAssertGreaterThan(clear, 1000, "and see-through around it")
        if ProcessInfo.processInfo.environment["ARTSY_DUMP_UI"] == "1" {
            let url = FileManager.default.temporaryDirectory.appendingPathComponent("artsy-preview-tile.png")
            try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: url)
            print("DUMP preview tile at \(url.path)")
        }
        // And back on paper, opaque, as the Studio has it
        let onPaper = try XCTUnwrap(preview.render(brush: .inkBrush, color: .black, size: 16))
        XCTAssertEqual(NSBitmapImageRep(cgImage: onPaper).colorAt(x: 2, y: 2)?.alphaComponent ?? 0, 1)
    }

    /// The whole panel lays out and draws; with ARTSY_DUMP_UI=1 the image is written out to
    /// look at, for the brush named by ARTSY_DUMP_BRUSH (Chalk otherwise).
    func testStudioViewRenders() throws {
        let harness = try EngineHarness(width: 64, height: 64)
        let named = ProcessInfo.processInfo.environment["ARTSY_DUMP_BRUSH"].flatMap(BrushDescriptor.builtIn(named:))
        harness.select(named ?? .chalk)
        harness.viewModel.currentColor = StrokeColor(red: 0.12, green: 0.33, blue: 0.70, alpha: 1)
        let model = BrushStudioModel(viewModel: harness.viewModel, library: library,
                                     previewRenderer: try BrushPreview(context: EngineHarness.sharedContext))
        model.renderPreviewNow()

        let hosting = NSHostingView(rootView: BrushStudioView(model: model, library: library))
        hosting.frame = NSRect(x: 0, y: 0, width: 440, height: 1180)
        let window = NSWindow(contentRect: hosting.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = hosting
        hosting.layoutSubtreeIfNeeded()
        let rep = try XCTUnwrap(hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds))
        hosting.cacheDisplay(in: hosting.bounds, to: rep)
        XCTAssertGreaterThan(rep.pixelsHigh, 100)

        if ProcessInfo.processInfo.environment["ARTSY_DUMP_UI"] == "1" {
            let url = FileManager.default.temporaryDirectory.appendingPathComponent("brush-studio.png")
            try rep.representation(using: .png, properties: [:])?.write(to: url)
            print("UI DUMP: \(url.path)")
        }
        window.contentView = nil
    }

    /// A tile rendered once is kept on disk: a cache with no renderer finds it, the same
    /// picture. An edited brush or another build gets a fresh tile, and a warm-up readies
    /// the library's tiles between turns of the run loop and drops what no brush uses.
    func testPreviewTilesAreKeptOnDiskByBrushAndBuild() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("artsy-tiles-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let files = { try FileManager.default.contentsOfDirectory(atPath: directory.path).filter { $0.hasSuffix(".png") } }
        let renderer = try BrushPreview(context: EngineHarness.sharedContext, size: BrushPreviewCache.size)
        let rendering = BrushPreviewCache(renderer: renderer, directory: directory, build: "24")
        let rendered = try XCTUnwrap(rendering.image(for: .inkBrush))
        XCTAssertEqual(try files().count, 1)

        // Found again without a renderer, and the same picture
        let kept = BrushPreviewCache(renderer: nil, directory: directory, build: "24")
        let found = try XCTUnwrap(kept.image(for: .inkBrush))
        XCTAssertEqual(found.size, rendered.size)
        let a = NSBitmapImageRep(cgImage: try XCTUnwrap(rendered.cgImage(forProposedRect: nil, context: nil, hints: nil)))
        let b = NSBitmapImageRep(cgImage: try XCTUnwrap(found.cgImage(forProposedRect: nil, context: nil, hints: nil)))
        var painted = 0, differing = 0
        for x in stride(from: 0, to: Int(BrushPreviewCache.size.width), by: 3) {
            for y in stride(from: 0, to: Int(BrushPreviewCache.size.height), by: 3) {
                let alphaA = a.colorAt(x: x, y: y)?.alphaComponent ?? -1
                let alphaB = b.colorAt(x: x, y: y)?.alphaComponent ?? -2
                if alphaA > 0.5 { painted += 1 }
                if abs(alphaA - alphaB) > 1.5 / 255 { differing += 1 }
            }
        }
        XCTAssertGreaterThan(painted, 50, "the stroke is there")
        XCTAssertEqual(differing, 0, "and the kept tile is the rendered one")

        // Not for an edited brush, nor for another build
        var edited = BrushDescriptor.inkBrush
        edited.opacity = 0.5
        XCTAssertNil(kept.image(for: edited))
        XCTAssertNil(BrushPreviewCache(renderer: nil, directory: directory, build: "25").image(for: .inkBrush))

        // A warm-up readies the rest, a tile a turn, and drops a tile of some other build
        let stale = directory.appendingPathComponent("stale.png")
        try Data("not a tile".utf8).write(to: stale)
        let library = BrushLibrary.shared.all
        rendering.warm(library, after: 0)
        let deadline = Date().addingTimeInterval(15)
        while try FileManager.default.fileExists(atPath: stale.path) || files().count < library.count, Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        }
        XCTAssertEqual(try files().count, library.count, "a tile for every brush")
        XCTAssertFalse(FileManager.default.fileExists(atPath: stale.path), "and the stale one gone")
    }
}
