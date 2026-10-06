import XCTest
import Metal
@testable import Artsy

/// Thick paint: height maps written by impasto brushes, lit by the display, and carried
/// through everything that moves paint.
final class ImpastoTests: XCTestCase {
    private let ochre = StrokeColor(red: 0.85, green: 0.55, blue: 0.15, alpha: 1)

    private func worst(_ a: PixelGrid, _ b: PixelGrid) -> Float {
        var worst: Float = 0
        for i in a.values.indices { worst = max(worst, abs(a.values[i] - b.values[i])) }
        return worst
    }

    /// A canvas with one Oil stroke across the middle of the drawing layer.
    private func canvasWithAStroke(width: Int = 200, height: Int = 120, size: Float = 40) throws -> EngineHarness {
        let harness = try EngineHarness(width: width, height: height)
        harness.select(.oil)
        harness.viewModel.brushSize = size
        harness.viewModel.currentColor = ochre
        harness.draw(StrokeFixtures.line(from: CGPoint(x: 30, y: 60), to: CGPoint(x: 170, y: 60), pressure: 1...1))
        return harness
    }

    // MARK: - Laying it down

    func testThickPaintRaisesTheLayerWhereItIsLaid() throws {
        let harness = try canvasWithAStroke()
        let once = harness.heights(of: harness.drawingLayer)
        XCTAssertGreaterThan(once.at(x: 100, y: 60).x, 0.3, "thick along the stroke")
        XCTAssertEqual(once.at(x: 100, y: 110).x, 0, accuracy: 0.001, "flat where nothing was painted")
        XCTAssertEqual(harness.heights(of: harness.backgroundLayer).at(x: 100, y: 60).x, 0, "and on other layers")

        harness.draw(StrokeFixtures.line(from: CGPoint(x: 30, y: 60), to: CGPoint(x: 170, y: 60), pressure: 1...1))
        let twice = harness.heights(of: harness.drawingLayer)
        XCTAssertGreaterThan(twice.at(x: 100, y: 60).x, once.at(x: 100, y: 60).x * 1.5, "a second pass builds it up")

        // A brush without impasto leaves the thickness alone
        harness.select(.softRound)
        harness.draw(StrokeFixtures.line(from: CGPoint(x: 30, y: 60), to: CGPoint(x: 170, y: 60), pressure: 1...1))
        XCTAssertEqual(worst(harness.heights(of: harness.drawingLayer), twice), 0)
    }

    func testTheEraserTakesThicknessAwayAndUndoPutsItBack() throws {
        let harness = try canvasWithAStroke()
        let painted = harness.heights(of: harness.drawingLayer)
        let paintedPixels = harness.pixels(of: harness.drawingLayer.texture)

        harness.select(.eraser)
        harness.viewModel.brushSize = 30
        harness.draw(StrokeFixtures.line(from: CGPoint(x: 100, y: 10), to: CGPoint(x: 100, y: 110), pressure: 1...1))
        let erased = harness.heights(of: harness.drawingLayer)
        XCTAssertLessThan(erased.at(x: 100, y: 60).x, 0.02, "flat where the eraser went")
        XCTAssertEqual(erased.at(x: 50, y: 60).x, painted.at(x: 50, y: 60).x, accuracy: 0.001, "untouched elsewhere")

        harness.viewModel.performUndo(renderer: harness.renderer)
        XCTAssertEqual(worst(harness.heights(of: harness.drawingLayer), painted), 0, "undo restores the thickness")
        XCTAssertEqual(worst(harness.pixels(of: harness.drawingLayer.texture), paintedPixels), 0, "and the paint")
        harness.viewModel.performUndo(renderer: harness.renderer)
        XCTAssertEqual(harness.heights(of: harness.drawingLayer).at(x: 100, y: 60).x, 0, accuracy: 0.001, "and before the stroke, flat")
        harness.viewModel.performRedo(renderer: harness.renderer)
        XCTAssertEqual(worst(harness.heights(of: harness.drawingLayer), painted), 0)
        harness.viewModel.performRedo(renderer: harness.renderer)
        XCTAssertEqual(worst(harness.heights(of: harness.drawingLayer), erased), 0)
    }

    /// A whole-stack undo step (as every non-stroke action takes) carries the thickness too.
    func testWholeStackSnapshotsCarryThickness() throws {
        let harness = try canvasWithAStroke()
        let painted = harness.heights(of: harness.drawingLayer)
        harness.viewModel.saveUndoSnapshot(renderer: harness.renderer, description: "Clear")
        let commandBuffer = harness.context.commandQueue.makeCommandBuffer()!
        harness.renderer.textureManager.clearTexture(harness.drawingLayer.heightTexture!, commandBuffer: commandBuffer)
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()
        XCTAssertEqual(harness.heights(of: harness.drawingLayer).at(x: 100, y: 60).x, 0)
        harness.viewModel.performUndo(renderer: harness.renderer)
        XCTAssertEqual(worst(harness.heights(of: harness.drawingLayer), painted), 0)
    }

    // MARK: - Lighting

    /// With the light at the top left, a stroke's left edge faces it and is lit, its right
    /// edge is shaded; flat paper is untouched; at zero relief the paint is flat.
    func testReliefLightsOneEdgeAndShadesTheOther() throws {
        let harness = try EngineHarness(width: 200, height: 120)
        harness.select(.oil)
        harness.viewModel.brushSize = 40
        harness.viewModel.currentColor = ochre
        harness.draw(StrokeFixtures.line(from: CGPoint(x: 100, y: 10), to: CGPoint(x: 100, y: 110), pressure: 1...1))
        func brightness(_ p: SIMD4<Float>) -> Float { (p.x + p.y + p.z) / 3 }

        let lit = harness.shown(relief: 1), flat = harness.shown(relief: 0)
        // Lit against flat at each column across the stroke, averaged along it. Where the
        // slopes are depends on the tip, so look for the brightest column on the left half
        // and the darkest on the right.
        let painted = (60...140).filter { brightness(flat.at(x: $0, y: 60)) < 0.9 }
        XCTAssertGreaterThan(painted.count, 10, "the stroke is \(painted.count) px wide")
        func ratio(_ x: Int) -> Float {
            let ys = Array(30...90)
            let litAverage = ys.map { brightness(lit.at(x: x, y: $0)) }.reduce(0, +)
            let flatAverage = ys.map { brightness(flat.at(x: x, y: $0)) }.reduce(0, +)
            return litAverage / flatAverage
        }
        let centre = (painted.min()! + painted.max()!) / 2
        let left = painted.filter { $0 < centre }.map(ratio), right = painted.filter { $0 > centre }.map(ratio)
        XCTAssertGreaterThan(left.max()!, 1.06, "lit on the left: \(left.map { String(format: "%.2f", $0) })")
        XCTAssertLessThan(right.min()!, 0.94, "shaded on the right: \(right.map { String(format: "%.2f", $0) })")
        XCTAssertGreaterThan(left.min()!, right.min()!, "and less shaded on the left than the right")

        XCTAssertEqual(brightness(lit.at(x: 20, y: 60)), 1, accuracy: 0.005, "the paper is still white")
        XCTAssertLessThan(worst(flat, harness.displayed()), 0.02, "at zero relief the display is the plain composite")
    }

    /// Two layers' thickness adds up on screen; a hidden layer's does not count.
    func testThicknessAddsUpAcrossLayers() throws {
        let harness = try canvasWithAStroke()
        let one = harness.shown()
        try harness.addLayer()
        harness.select(.oil)
        harness.viewModel.brushSize = 40
        harness.viewModel.currentColor = ochre
        harness.draw(StrokeFixtures.line(from: CGPoint(x: 100, y: 10), to: CGPoint(x: 100, y: 110), pressure: 1...1))
        XCTAssertGreaterThan(worst(harness.shown(), one), 0.05)
        harness.layerStack.layers[2].isVisible = false
        XCTAssertLessThan(worst(harness.shown(), one), 0.01, "hidden, the second layer's relief goes too")
    }

    // MARK: - Moving paint

    func testThicknessMovesWithThePaint() throws {
        // The move tool shifts the whole layer
        var harness = try canvasWithAStroke()
        harness.renderer.shiftLayerContent(layer: harness.drawingLayer, dx: 0, dy: 30, context: harness.context)
        var heights = harness.heights(of: harness.drawingLayer)
        XCTAssertEqual(heights.at(x: 100, y: 60).x, 0, accuracy: 0.001, "gone from where it was")
        XCTAssertGreaterThan(heights.at(x: 100, y: 30).x, 0.3, "30 px down (texture rows run downward)")

        // A selection cut out, dragged and put down
        harness = try canvasWithAStroke()
        let mover = SelectionMoveHandler()
        let selection = CGPath(rect: CGRect(x: 60, y: 30, width: 80, height: 60), transform: nil)
        mover.begin(selectionPath: selection, layer: harness.drawingLayer, context: harness.context,
                    textureManager: harness.renderer.textureManager)
        XCTAssertEqual(harness.heights(of: harness.drawingLayer).at(x: 100, y: 60).x, 0, accuracy: 0.001, "cut out")
        XCTAssertGreaterThan(harness.heights(of: harness.drawingLayer).at(x: 40, y: 60).x, 0.3, "outside the selection stays")
        mover.updateOffset(dx: 0, dy: -30)
        mover.commit(layer: harness.drawingLayer, context: harness.context,
                     textureManager: harness.renderer.textureManager, compositor: harness.renderer.compositor)
        heights = harness.heights(of: harness.drawingLayer)
        XCTAssertGreaterThan(heights.at(x: 100, y: 30).x, 0.3, "put down 30 px lower")
        XCTAssertEqual(heights.at(x: 100, y: 60).x, 0, accuracy: 0.001)

        // The transform tool
        harness = try canvasWithAStroke()
        let session = try XCTUnwrap(TransformSession.begin(
            targetLayer: harness.drawingLayer, canvasSize: harness.viewModel.canvasSize, selectionPath: nil,
            context: harness.context, textureManager: harness.renderer.textureManager
        ))
        session.currentTransform = CGAffineTransform(translationX: 0, y: -30)
        session.commit(context: harness.context, textureManager: harness.renderer.textureManager,
                       compositor: harness.renderer.compositor)
        heights = harness.heights(of: harness.drawingLayer)
        XCTAssertGreaterThan(heights.at(x: 100, y: 30).x, 0.3, "moved down by the transform")
        XCTAssertEqual(heights.at(x: 100, y: 60).x, 0, accuracy: 0.001)

        // Clearing a selection clears its thickness
        harness = try canvasWithAStroke()
        harness.renderer.clearInsideSelection(path: selection, layer: harness.drawingLayer, context: harness.context)
        heights = harness.heights(of: harness.drawingLayer)
        XCTAssertEqual(heights.at(x: 100, y: 60).x, 0, accuracy: 0.001)
        XCTAssertGreaterThan(heights.at(x: 40, y: 60).x, 0.3)
    }

    func testFlatteningAndMergingKeepTheThickness() throws {
        let harness = try canvasWithAStroke()
        try harness.addLayer()
        harness.select(.oil)
        harness.viewModel.brushSize = 40
        harness.viewModel.currentColor = ochre
        harness.draw(StrokeFixtures.line(from: CGPoint(x: 30, y: 60), to: CGPoint(x: 170, y: 60), pressure: 1...1))
        let each = harness.heights(of: harness.layerStack.layers[1]).at(x: 100, y: 60).x
        XCTAssertGreaterThan(each, 0.3)

        XCTAssertTrue(harness.layerStack.mergeDown(at: 2, renderer: harness.renderer))
        XCTAssertEqual(harness.heights(of: harness.layerStack.layers[1]).at(x: 100, y: 60).x, each * 2, accuracy: 0.01)

        let flattened = try harness.layerStack.flattenAll(renderer: harness.renderer)
        XCTAssertEqual(harness.heights(of: flattened).at(x: 100, y: 60).x, each * 2, accuracy: 0.01)
    }

    // MARK: - Files

    func testThicknessSurvivesSaveAndLoad() throws {
        let harness = try canvasWithAStroke()
        let heights = harness.heights(of: harness.drawingLayer)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("ArtsyImpasto-\(UUID().uuidString).artsy")
        defer { try? FileManager.default.removeItem(at: url) }

        let saved = expectation(description: "saved")
        CanvasDocument.saveAsync(renderer: harness.renderer, viewModel: harness.viewModel, to: url) { result in
            if case .failure(let error) = result { XCTFail("\(error)") }
            saved.fulfill()
        }
        wait(for: [saved], timeout: 10)
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.appendingPathComponent("layers/layer-1-height.png").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.appendingPathComponent("layers/layer-0-height.png").path),
                       "a flat layer saves no height map")

        let loaded = try CanvasDocument.load(from: url, metalContext: harness.context)
        let layer = loaded.viewModel.layerStack.layers[1]
        XCTAssertNotNil(layer.heightTexture)
        XCTAssertNil(loaded.viewModel.layerStack.layers[0].heightTexture)
        XCTAssertGreaterThan(heights.at(x: 100, y: 60).x, 0.3)
        XCTAssertLessThan(worst(harness.heights(of: layer), heights), 0.002, "16-bit on disk, 0...8")
    }

    func testImpastoSettingsSurviveTheBrushFile() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ArtsyImpasto-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let library = BrushLibrary(directory: directory)
        let file = directory.appendingPathComponent("oil.artsybrush")
        try library.export(.oil, to: file)
        XCTAssertTrue(try String(contentsOf: file, encoding: .utf8).contains("\"thickness\""))
        XCTAssertEqual(try library.importBrush(from: file).rendering, BrushDescriptor.oil.rendering)
    }
}
