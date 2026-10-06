import XCTest
import ImageIO
@testable import Artsy

/// Big canvases and many layers: limits that follow memory, undo history that shares
/// unchanged layers and stays under a cap, 16-bit export.
final class ScaleTests: XCTestCase {
    private func worst(_ a: PixelGrid, _ b: PixelGrid) -> Float {
        var worst: Float = 0
        for i in a.values.indices { worst = max(worst, abs(a.values[i] - b.values[i])) }
        return worst
    }

    // MARK: - Layers

    func testTheLayerLimitFollowsTheCanvasSizeAndTheMemory() throws {
        let gigabyte = 1 << 30
        XCTAssertEqual(LayerStack.layerLimit(forCanvasPixels: 2048 * 2048, memoryBudget: 16 * gigabyte), 32)
        XCTAssertEqual(LayerStack.layerLimit(forCanvasPixels: 8192 * 8192, memoryBudget: 16 * gigabyte), 12)
        XCTAssertEqual(LayerStack.layerLimit(forCanvasPixels: 8192 * 8192, memoryBudget: 4 * gigabyte), 3)
        XCTAssertEqual(LayerStack.layerLimit(forCanvasPixels: 8192 * 8192, memoryBudget: 1 * gigabyte), 2, "never fewer than two")

        let harness = try EngineHarness(width: 256, height: 256)
        XCTAssertEqual(harness.layerStack.layerLimit, 32, "a small canvas gets them all")
        harness.layerStack.memoryBudgetOverride = 256 * 256 * 10 * 2 * 4   // room for four
        XCTAssertEqual(harness.layerStack.layerLimit, 4)
        try harness.addLayer()
        try harness.addLayer()
        XCTAssertEqual(harness.layerStack.layers.count, 4)
        XCTAssertThrowsError(try harness.addLayer()) { error in
            XCTAssertTrue("\(error.localizedDescription)".contains("4"), error.localizedDescription)
        }
    }

    // MARK: - Undo

    /// Whole-stack snapshots copy every layer, but layers that have not changed since the
    /// last one end up sharing its copies.
    func testSnapshotsShareLayersThatDidNotChange() throws {
        let harness = try EngineHarness(width: 256, height: 256)
        try harness.addLayer()
        let undo = harness.viewModel.undoManager
        let layerBytes = 256 * 256 * 8

        harness.viewModel.saveUndoSnapshot(renderer: harness.renderer, description: "First")
        undo.waitForPendingWork()
        XCTAssertEqual(undo.textureBytes, 3 * layerBytes, "three layers copied")

        // Nothing changed: the second snapshot adds nothing once the GPU has compared
        harness.viewModel.saveUndoSnapshot(renderer: harness.renderer, description: "Rename")
        undo.waitForPendingWork()
        XCTAssertEqual(undo.textureBytes, 3 * layerBytes, "nothing new to keep")
        XCTAssertEqual(undo.undoCount, 2)

        // One layer painted: only it is copied again
        harness.draw(StrokeFixtures.line(from: CGPoint(x: 20, y: 128), to: CGPoint(x: 230, y: 128)))
        let strokeBytes = undo.textureBytes - 3 * layerBytes
        XCTAssertGreaterThan(strokeBytes, 0)
        XCTAssertLessThan(strokeBytes, layerBytes, "a stroke keeps its rectangle only")
        harness.viewModel.saveUndoSnapshot(renderer: harness.renderer, description: "Fill")
        undo.waitForPendingWork()
        XCTAssertEqual(undo.textureBytes, 4 * layerBytes + strokeBytes, "one layer changed, one copy added")

        // And undoing through them still restores the right pixels
        let painted = harness.pixels(of: harness.drawingLayer.texture)
        harness.fill(harness.drawingLayer, red: 1, green: 0, blue: 0)
        harness.viewModel.performUndo(renderer: harness.renderer)   // the fill
        XCTAssertEqual(worst(harness.pixels(of: harness.drawingLayer.texture), painted), 0)
        harness.viewModel.performUndo(renderer: harness.renderer)   // the stroke
        harness.viewModel.performUndo(renderer: harness.renderer)   // "Rename"
        harness.viewModel.performUndo(renderer: harness.renderer)   // "First"
        XCTAssertEqual(harness.pixels(of: harness.drawingLayer.texture).at(x: 128, y: 128).w, 0, "back to blank")
        harness.viewModel.performRedo(renderer: harness.renderer)
        harness.viewModel.performRedo(renderer: harness.renderer)
        harness.viewModel.performRedo(renderer: harness.renderer)
        XCTAssertEqual(worst(harness.pixels(of: harness.drawingLayer.texture), painted), 0, "and forward again")
    }

    /// However big the canvas, the history stays under the memory cap.
    func testUndoHistoryStaysUnderTheMemoryCap() throws {
        let harness = try EngineHarness(width: 256, height: 256)
        let undo = harness.viewModel.undoManager
        let layerBytes = 256 * 256 * 8
        undo.memoryCap = 5 * layerBytes   // two whole-stack snapshots of two layers, plus a little

        for i in 0..<6 {
            harness.fill(harness.drawingLayer, red: Double(i) / 6, green: 0, blue: 0)   // so each snapshot differs
            harness.viewModel.saveUndoSnapshot(renderer: harness.renderer, description: "Fill \(i)")
            undo.waitForPendingWork()
        }
        XCTAssertLessThanOrEqual(undo.textureBytes, undo.memoryCap + 2 * layerBytes, "within a snapshot of the cap")
        XCTAssertLessThan(undo.undoCount, 6, "the oldest steps were dropped")
        XCTAssertGreaterThanOrEqual(undo.undoCount, 1)
    }

    func testMemoryReadoutCountsLayersScratchAndUndo() throws {
        let harness = try EngineHarness(width: 256, height: 256)
        let pixelBytes = 256 * 256
        let before = harness.viewModel.memoryUseBytes
        XCTAssertGreaterThanOrEqual(before, pixelBytes * 8 * 2, "two layers at least")
        try harness.addLayer()
        XCTAssertEqual(harness.viewModel.memoryUseBytes - before, pixelBytes * 8, "a layer more")
        harness.draw(StrokeFixtures.line(from: CGPoint(x: 20, y: 128), to: CGPoint(x: 230, y: 128)))
        XCTAssertGreaterThan(harness.viewModel.memoryUseBytes, before + pixelBytes * 8, "and the stroke's undo step")
    }

    // MARK: - Export

    func testSixteenBitExportKeepsMoreThanEightBitsAndMatchesTheScreen() throws {
        let harness = try EngineHarness(width: 128, height: 64)
        harness.select(.softRound)
        harness.viewModel.brushSize = 40
        harness.viewModel.currentColor = StrokeColor(red: 0.2, green: 0.5, blue: 0.9, alpha: 1)
        harness.draw(StrokeFixtures.line(from: CGPoint(x: 10, y: 32), to: CGPoint(x: 118, y: 32), pressure: 0.2...1.0))
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ArtsyExport-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let eight = directory.appendingPathComponent("8.png"), sixteen = directory.appendingPathComponent("16.png")
        try ImageExporter.exportPNG(renderer: harness.renderer, to: eight)
        try ImageExporter.exportPNG(renderer: harness.renderer, to: sixteen, bitsPerChannel: 16)

        func image(_ url: URL) throws -> CGImage {
            let source = try XCTUnwrap(CGImageSourceCreateWithURL(url as CFURL, nil))
            return try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
        }
        let image8 = try image(eight), image16 = try image(sixteen)
        XCTAssertEqual(image8.bitsPerComponent, 8)
        XCTAssertEqual(image16.bitsPerComponent, 16)
        XCTAssertEqual(image16.colorSpace?.name as String?, CGColorSpace.displayP3 as String, "tagged as the canvas is drawn")
        XCTAssertEqual(image8.colorSpace?.name as String?, CGColorSpace.displayP3 as String)

        // The 16-bit file holds the shown pixels more finely than the 8-bit one. Read both
        // through contexts of known layout (a PNG without alpha decodes as three channels).
        let shown = harness.shown(relief: 0)
        let p3 = CGColorSpace(name: CGColorSpace.displayP3)!
        let ctx16 = try XCTUnwrap(CGContext(
            data: nil, width: 128, height: 64, bitsPerComponent: 16, bytesPerRow: 128 * 8, space: p3,
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue | CGBitmapInfo.byteOrder16Little.rawValue
        ))
        ctx16.draw(image16, in: CGRect(x: 0, y: 0, width: 128, height: 64))
        let wide = try XCTUnwrap(ctx16.data).bindMemory(to: UInt16.self, capacity: 128 * 64 * 4)
        let ctx8 = try XCTUnwrap(CGContext(
            data: nil, width: 128, height: 64, bitsPerComponent: 8, bytesPerRow: 128 * 4, space: p3,
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        ))
        ctx8.draw(image8, in: CGRect(x: 0, y: 0, width: 128, height: 64))
        let narrow = try XCTUnwrap(ctx8.data).bindMemory(to: UInt8.self, capacity: 128 * 64 * 4)

        var reds16 = Set<UInt16>(), reds8 = Set<UInt8>()
        var worstError: Float = 0
        for y in 0..<64 {
            for x in 0..<128 {
                let value = wide[(y * (ctx16.bytesPerRow / 2)) + x * 4]    // red: the channel the stroke changes most
                reds16.insert(value)
                reds8.insert(narrow[(y * ctx8.bytesPerRow) + x * 4])
                worstError = max(worstError, abs(Float(value) / 65535 - shown.at(x: x, y: 63 - y).x))
            }
        }
        XCTAssertLessThan(worstError, 1.5 / 255, "the 8-bit screen read and the 16-bit file agree")
        XCTAssertGreaterThan(reds16.count, reds8.count * 2, "more distinct reds in 16 bits: \(reds16.count) vs \(reds8.count)")
        XCTAssertGreaterThan(reds8.count, 100, "a soft stroke from 0.2 to 1.0 spans most of 8 bits")
    }

    /// A device that reports no working-set size is not short of memory, just silent.
    func testADeviceWithoutABudgetGetsTheFullLayerCount() {
        XCTAssertEqual(LayerStack.layerLimit(forCanvasPixels: 8192 * 8192, memoryBudget: 0), LayerStack.maxLayers)
        XCTAssertEqual(LayerStack.layerLimit(forCanvasPixels: 64 * 64, memoryBudget: 0), LayerStack.maxLayers)
    }
}
