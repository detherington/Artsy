import XCTest
@testable import Artsy

final class UndoTests: XCTestCase {
    private func worstDifference(_ a: PixelGrid, _ b: PixelGrid) -> Float {
        var worst: Float = 0
        for i in a.values.indices { worst = max(worst, abs(a.values[i] - b.values[i])) }
        return worst
    }

    func testUndoAndRedoOfStrokesRestoreTheLayerExactly() throws {
        let harness = try EngineHarness(width: 256, height: 256)
        let viewModel = harness.viewModel, renderer = harness.renderer
        harness.fill(harness.drawingLayer, red: 0.2, green: 0.5, blue: 0.9, alpha: 0.6)
        func layer() -> PixelGrid { harness.pixels(of: harness.drawingLayer.texture) }

        let blank = layer()
        harness.select(.softRound)
        harness.viewModel.currentColor = StrokeColor(red: 0.8, green: 0.1, blue: 0.1, alpha: 1)
        harness.draw(StrokeFixtures.wave(from: CGPoint(x: 20, y: 180), length: 200, amplitude: 30, cycles: 2))
        let afterFirst = layer()
        harness.select(.eraser)
        harness.draw(StrokeFixtures.line(from: CGPoint(x: 128, y: 20), to: CGPoint(x: 128, y: 240), pressure: 1...1))
        let afterSecond = layer()
        XCTAssertGreaterThan(worstDifference(blank, afterFirst), 0.1)
        XCTAssertGreaterThan(worstDifference(afterFirst, afterSecond), 0.1)
        XCTAssertTrue(viewModel.isDirty)

        viewModel.performUndo(renderer: renderer)
        XCTAssertEqual(worstDifference(layer(), afterFirst), 0)
        viewModel.performUndo(renderer: renderer)
        XCTAssertEqual(worstDifference(layer(), blank), 0)
        XCTAssertFalse(viewModel.undoManager.canUndo)

        viewModel.performRedo(renderer: renderer)
        XCTAssertEqual(worstDifference(layer(), afterFirst), 0)
        viewModel.performRedo(renderer: renderer)
        XCTAssertEqual(worstDifference(layer(), afterSecond), 0)
        XCTAssertFalse(viewModel.undoManager.canRedo)
    }

    /// Strokes save a rectangle; other actions still save the whole stack. They share one history.
    func testStrokesAndWholeStackSnapshotsUndoInOrder() throws {
        let harness = try EngineHarness(width: 128, height: 128)
        let viewModel = harness.viewModel, renderer = harness.renderer
        func layer() -> PixelGrid { harness.pixels(of: harness.drawingLayer.texture) }

        harness.draw(StrokeFixtures.line(from: CGPoint(x: 10, y: 100), to: CGPoint(x: 110, y: 100)))
        let oneStroke = layer()

        viewModel.saveUndoSnapshot(renderer: renderer, description: "Add Layer")
        _ = try harness.layerStack.addLayer(above: 1)
        harness.layerStack.activeLayerIndex = 1
        harness.draw(StrokeFixtures.line(from: CGPoint(x: 10, y: 30), to: CGPoint(x: 110, y: 30)))
        XCTAssertEqual(harness.layerStack.layers.count, 3)

        viewModel.performUndo(renderer: renderer)   // second stroke
        XCTAssertEqual(worstDifference(layer(), oneStroke), 0)
        XCTAssertEqual(harness.layerStack.layers.count, 3)

        viewModel.performUndo(renderer: renderer)   // add layer
        XCTAssertEqual(harness.layerStack.layers.count, 2)
        XCTAssertEqual(worstDifference(layer(), oneStroke), 0)

        viewModel.performUndo(renderer: renderer)   // first stroke
        XCTAssertEqual(layer().values.max(), 0)

        viewModel.performRedo(renderer: renderer)
        viewModel.performRedo(renderer: renderer)
        viewModel.performRedo(renderer: renderer)
        XCTAssertEqual(harness.layerStack.layers.count, 3)
        XCTAssertGreaterThan(worstDifference(layer(), oneStroke), 0.1, "the second stroke is back")
    }

    func testAStrokeOnlyStoresTheRectangleItTouched() throws {
        let harness = try EngineHarness(width: 1024, height: 1024)
        harness.viewModel.brushSize = 20
        harness.draw(StrokeFixtures.line(from: CGPoint(x: 100, y: 500), to: CGPoint(x: 400, y: 500)))

        let wholeLayer = 1024 * 1024 * 8
        XCTAssertGreaterThan(harness.viewModel.undoManager.textureBytes, 0)
        XCTAssertLessThan(harness.viewModel.undoManager.textureBytes, wholeLayer / 50)
    }

    func testAStrokeThatDrawsNothingAddsNoUndoStep() throws {
        let harness = try EngineHarness(width: 128, height: 128)
        // Entirely off the canvas
        harness.draw(StrokeFixtures.line(from: CGPoint(x: 300, y: 300), to: CGPoint(x: 400, y: 300)))
        XCTAssertFalse(harness.viewModel.undoManager.canUndo)
        XCTAssertFalse(harness.viewModel.isDirty)
    }
}
