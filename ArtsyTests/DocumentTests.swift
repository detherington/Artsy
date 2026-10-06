import XCTest
import ImageIO
import UniformTypeIdentifiers
@testable import Artsy

/// The document on disk: what a save leaves behind, what a load makes of it.
final class DocumentTests: XCTestCase {
    private let fm = FileManager.default

    private func temporaryDocumentURL() -> URL {
        fm.temporaryDirectory.appendingPathComponent("ArtsyDocumentTests-\(UUID().uuidString).artsy")
    }

    private func save(_ harness: EngineHarness, to url: URL) throws {
        let saved = expectation(description: "saved")
        var failure: Error?
        CanvasDocument.saveAsync(renderer: harness.renderer, viewModel: harness.viewModel, to: url) { result in
            if case .failure(let error) = result { failure = error }
            saved.fulfill()
        }
        wait(for: [saved], timeout: 20)
        if let failure { throw failure }
    }

    private func worst(_ a: PixelGrid, _ b: PixelGrid) -> Float {
        var worst: Float = 0
        for i in a.values.indices { worst = max(worst, abs(a.values[i] - b.values[i])) }
        return worst
    }

    /// Every save writes the document afresh: a layer that lost its thickness, or went,
    /// leaves no file behind for the layer that takes its place in the list to inherit.
    func testSavingAgainLeavesNothingFromAnEarlierSave() throws {
        let harness = try EngineHarness(width: 96, height: 64)
        harness.select(.oil)
        harness.viewModel.brushSize = 20
        harness.draw(StrokeFixtures.line(from: CGPoint(x: 10, y: 32), to: CGPoint(x: 86, y: 32), pressure: 1...1))
        let green = try harness.addLayer()
        harness.fill(green, red: 0, green: 1, blue: 0)
        let url = temporaryDocumentURL()
        defer { try? fm.removeItem(at: url) }
        let layers = url.appendingPathComponent("layers")

        try save(harness, to: url)
        XCTAssertTrue(fm.fileExists(atPath: layers.appendingPathComponent("layer-1-height.png").path))
        XCTAssertTrue(fm.fileExists(atPath: layers.appendingPathComponent("layer-2.png").path))

        // The thick layer goes; the green one takes its place in the list
        harness.layerStack.removeLayer(at: 1)
        try save(harness, to: url)
        XCTAssertFalse(fm.fileExists(atPath: layers.appendingPathComponent("layer-1-height.png").path),
                       "no thickness file for a layer that has none")
        XCTAssertFalse(fm.fileExists(atPath: layers.appendingPathComponent("layer-2.png").path),
                       "no file for a layer that is gone")
        let loaded = try CanvasDocument.load(from: url, metalContext: harness.context)
        XCTAssertEqual(loaded.viewModel.layerStack.layers.count, 2)
        XCTAssertNil(loaded.viewModel.layerStack.layers[1].heightTexture, "the green layer did not inherit the relief")
        XCTAssertEqual(harness.pixels(of: loaded.viewModel.layerStack.layers[1].texture).at(x: 48, y: 32).y, 1, accuracy: 0.01)
        XCTAssertEqual(try fm.contentsOfDirectory(atPath: url.deletingLastPathComponent().path)
                        .filter { $0.contains(url.lastPathComponent) }.count, 1, "no staging left beside the document")
    }

    /// Layer files hold the canvas's own Display P3 components. Files from before the
    /// profile was right say sRGB, and must be taken as they are, not converted.
    func testLayerFilesFromBeforeTheProfileWasRightLoadAsTheyWere() throws {
        let harness = try EngineHarness(width: 64, height: 64)
        harness.fill(harness.drawingLayer, red: 0.9, green: 0.2, blue: 0.1)
        let url = temporaryDocumentURL()
        defer { try? fm.removeItem(at: url) }
        try save(harness, to: url)
        let file = url.appendingPathComponent("layers/layer-1.png")

        let fresh = try CanvasDocument.load(from: url, metalContext: harness.context)
        let freshPixel = harness.pixels(of: fresh.viewModel.layerStack.layers[1].texture).at(x: 32, y: 32)
        XCTAssertEqual(freshPixel.x, 0.9, accuracy: 0.01)
        XCTAssertEqual(freshPixel.y, 0.2, accuracy: 0.01)

        // The same file with the profile older versions wrote
        let image = try XCTUnwrap(CGImageSourceCreateWithURL(file as CFURL, nil).flatMap { CGImageSourceCreateImageAtIndex($0, 0, nil) })
        XCTAssertEqual(image.colorSpace?.name as String?, CGColorSpace.displayP3 as String, "saved as what it is")
        let retagged = try XCTUnwrap(image.copy(colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!))
        let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(file as CFURL, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, retagged, nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))

        let legacy = try CanvasDocument.load(from: url, metalContext: harness.context)
        let legacyPixel = harness.pixels(of: legacy.viewModel.layerStack.layers[1].texture).at(x: 32, y: 32)
        XCTAssertEqual(legacyPixel.x, 0.9, accuracy: 0.01, "taken as the canvas's own components")
        XCTAssertEqual(legacyPixel.y, 0.2, accuracy: 0.01)
    }

    /// A file can say any size; the engine holds canvases up to its limit.
    func testADocumentWithAnImpossibleSizeIsRefused() throws {
        for (width, height) in [(0, 64), (64, -1), (100_000, 64)] {
            let url = temporaryDocumentURL()
            defer { try? fm.removeItem(at: url) }
            try fm.createDirectory(at: url, withIntermediateDirectories: true)
            let json = "{\"version\":1,\"canvasWidth\":\(width),\"canvasHeight\":\(height),\"layers\":[],\"activeLayerIndex\":0}"
            try json.write(to: url.appendingPathComponent("document.json"), atomically: true, encoding: .utf8)
            XCTAssertThrowsError(try CanvasDocument.load(from: url, metalContext: EngineHarness.sharedContext), "\(width) × \(height)")
        }
    }

    /// Saving reads the layers; what is on screen is left alone, and the thumbnail shows
    /// the layers as the screen does, blend modes and all.
    func testSavingLeavesTheScreenAloneAndTheThumbnailMatchesIt() throws {
        let harness = try EngineHarness(width: 64, height: 64)
        harness.fill(harness.drawingLayer, red: 0.8, green: 0.8, blue: 0.2)
        let upper = try harness.addLayer(blendMode: .multiply)
        harness.fill(upper, red: 0.2, green: 0.9, blue: 0.9)
        harness.renderFrameAsTheAppWould()
        let shown = harness.composite()
        XCTAssertEqual(shown.at(x: 32, y: 32).x, 0.16, accuracy: 0.01, "multiplied")

        let url = temporaryDocumentURL()
        defer { try? fm.removeItem(at: url) }
        try save(harness, to: url)
        harness.renderFrameAsTheAppWould()   // idle: the composite stands, and must still be right
        XCTAssertEqual(worst(harness.composite(), shown), 0, accuracy: 0.001)

        let thumbnail = try XCTUnwrap(CGImageSourceCreateWithURL(url.appendingPathComponent("thumbnail.png") as CFURL, nil)
            .flatMap { CGImageSourceCreateImageAtIndex($0, 0, nil) })
        var rgba = [UInt8](repeating: 0, count: 64 * 64 * 4)
        rgba.withUnsafeMutableBytes { raw in
            let context = CGContext(data: raw.baseAddress, width: 64, height: 64, bitsPerComponent: 8, bytesPerRow: 64 * 4,
                                    space: CGColorSpace(name: CGColorSpace.displayP3)!,
                                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            context.draw(thumbnail, in: CGRect(x: 0, y: 0, width: 64, height: 64))
        }
        let centre = (32 * 64 + 32) * 4
        XCTAssertEqual(Float(rgba[centre]) / 255, 0.16, accuracy: 0.02, "the thumbnail multiplies too")
        XCTAssertEqual(Float(rgba[centre + 1]) / 255, 0.72, accuracy: 0.02)
    }
}
