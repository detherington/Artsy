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

    /// Strokes are cheap to keep, so history goes well past the old 25 steps.
    func testManyStrokesCanBeUndone() throws {
        let harness = try EngineHarness(width: 256, height: 256)
        for index in 0..<60 {
            let y = CGFloat(10 + index * 4)
            harness.draw(StrokeFixtures.line(from: CGPoint(x: 20, y: y), to: CGPoint(x: 230, y: y)), pointsPerFrame: .max)
        }
        XCTAssertEqual(harness.viewModel.undoManager.undoCount, 60)
        for _ in 0..<60 { harness.viewModel.performUndo(renderer: harness.renderer) }
        XCTAssertFalse(harness.viewModel.undoManager.canUndo)
        XCTAssertEqual(harness.pixels(of: harness.drawingLayer.texture).values.max(), 0, "back to an empty layer")
    }

    /// Whole-stack snapshots are what memory is budgeted in: 25 of them fit, as before.
    func testWholeStackSnapshotsAreLimitedByMemory() throws {
        let harness = try EngineHarness(width: 256, height: 256)
        let undo = harness.viewModel.undoManager
        for index in 0..<10 {
            harness.draw(StrokeFixtures.line(from: CGPoint(x: 20, y: CGFloat(20 + index * 8)), to: CGPoint(x: 230, y: 100)),
                         pointsPerFrame: .max)
        }
        // Every step changes both layers, so each snapshot has to keep copies of both
        for index in 0..<40 {
            harness.viewModel.saveUndoSnapshot(renderer: harness.renderer, description: "Fill everything")
            undo.waitForPendingWork()
            harness.fill(harness.backgroundLayer, red: Double(index) / 40, green: 0.5, blue: 0.5)
            harness.fill(harness.drawingLayer, red: 0.5, green: Double(index) / 40, blue: 0.5, alpha: 0.5)
        }
        XCTAssertEqual(undo.undoCount, undo.wholeStackSnapshotsInBudget, "the oldest steps were dropped to stay in budget")
        XCTAssertLessThanOrEqual(undo.textureBytes, 2 * 256 * 256 * 8 * undo.wholeStackSnapshotsInBudget)
    }

    func testAStrokeThatDrawsNothingAddsNoUndoStep() throws {
        let harness = try EngineHarness(width: 128, height: 128)
        // Entirely off the canvas
        harness.draw(StrokeFixtures.line(from: CGPoint(x: 300, y: 300), to: CGPoint(x: 400, y: 300)))
        XCTAssertFalse(harness.viewModel.undoManager.canUndo)
        XCTAssertFalse(harness.viewModel.isDirty)
    }

    /// A snapshot copies only the layers the action says it will change; the rest are
    /// referenced, and come back right because every later change is undone first.
    func testSnapshotsCopyOnlyWhatTheActionChanges() throws {
        let harness = try EngineHarness(width: 128, height: 128)
        let viewModel = harness.viewModel, renderer = harness.renderer, undo = viewModel.undoManager
        let layerBytes = 128 * 128 * 8
        harness.draw(StrokeFixtures.line(from: CGPoint(x: 10, y: 64), to: CGPoint(x: 118, y: 64)))
        let drawn = harness.pixels(of: harness.drawingLayer.texture)
        let strokeBytes = undo.textureBytes

        // A selection: nothing copied, and undo brings the selection back
        viewModel.saveUndoSnapshot(renderer: renderer, description: "Select", changing: .nothing)
        viewModel.selectionPath = CGPath(rect: CGRect(x: 10, y: 10, width: 50, height: 50), transform: nil)
        XCTAssertEqual(undo.textureBytes, strokeBytes, "a selection copies no pixels")
        viewModel.performUndo(renderer: renderer)
        XCTAssertNil(viewModel.selectionPath)
        XCTAssertEqual(worstDifference(harness.pixels(of: harness.drawingLayer.texture), drawn), 0, "pixels untouched")
        viewModel.performRedo(renderer: renderer)
        XCTAssertNotNil(viewModel.selectionPath)

        // Deleting a layer: nothing copied, and undo brings the layer back with its pixels
        viewModel.saveUndoSnapshot(renderer: renderer, description: "Delete Layer", changing: .nothing)
        harness.layerStack.removeLayer(at: 1)
        XCTAssertEqual(harness.layerStack.layers.count, 1)
        XCTAssertEqual(undo.textureBytes, strokeBytes)
        viewModel.performUndo(renderer: renderer)
        XCTAssertEqual(harness.layerStack.layers.count, 2)
        XCTAssertEqual(worstDifference(harness.pixels(of: harness.layerStack.layers[1].texture), drawn), 0, "the deleted layer is back as it was")

        // A fill of one layer copies that layer only
        viewModel.saveUndoSnapshot(renderer: renderer, description: "Fill", changing: .layer(harness.drawingLayer))
        XCTAssertEqual(undo.textureBytes, strokeBytes + layerBytes)
        harness.fill(harness.drawingLayer, red: 1, green: 0, blue: 0)
        viewModel.performUndo(renderer: renderer)
        XCTAssertEqual(worstDifference(harness.pixels(of: harness.drawingLayer.texture), drawn), 0)

        // Merging down: the lower layer is copied, the upper referenced, and both come back
        try harness.addLayer()
        harness.layerStack.activeLayerIndex = 2
        harness.draw(StrokeFixtures.line(from: CGPoint(x: 64, y: 10), to: CGPoint(x: 64, y: 118)))
        let upper = harness.pixels(of: harness.layerStack.layers[2].texture)
        viewModel.saveUndoSnapshot(renderer: renderer, description: "Merge Down", changing: .layer(harness.layerStack.layers[1]))
        XCTAssertTrue(harness.layerStack.mergeDown(at: 2, renderer: renderer))
        XCTAssertEqual(harness.layerStack.layers.count, 2)
        XCTAssertGreaterThan(worstDifference(harness.pixels(of: harness.layerStack.layers[1].texture), drawn), 0.5, "merged")
        viewModel.performUndo(renderer: renderer)
        XCTAssertEqual(harness.layerStack.layers.count, 3)
        XCTAssertEqual(worstDifference(harness.pixels(of: harness.layerStack.layers[1].texture), drawn), 0, "the lower layer as it was")
        XCTAssertEqual(worstDifference(harness.pixels(of: harness.layerStack.layers[2].texture), upper), 0, "the upper layer as it was")
    }

    /// Idle, with nothing changed, a frame does not rebuild the composite; a change does.
    func testIdleFramesSkipTheComposite() throws {
        let harness = try EngineHarness(width: 128, height: 128)
        let renderer = harness.renderer
        harness.renderFrameAsTheAppWould()
        XCTAssertTrue(renderer.lastFrameRecomposited, "the first frame")
        harness.renderFrameAsTheAppWould()
        XCTAssertFalse(renderer.lastFrameRecomposited, "nothing changed")

        harness.drawingLayer.opacity = 0.5
        harness.renderFrameAsTheAppWould()
        XCTAssertTrue(renderer.lastFrameRecomposited, "a layer setting changed")
        harness.renderFrameAsTheAppWould()
        XCTAssertFalse(renderer.lastFrameRecomposited)

        harness.viewModel.markDirty()
        harness.renderFrameAsTheAppWould()
        XCTAssertTrue(renderer.lastFrameRecomposited, "something was marked changed")

        harness.draw(StrokeFixtures.line(from: CGPoint(x: 10, y: 64), to: CGPoint(x: 118, y: 64)))
        harness.renderFrameAsTheAppWould()
        XCTAssertTrue(renderer.lastFrameRecomposited, "after a stroke")
        harness.renderFrameAsTheAppWould()
        XCTAssertFalse(renderer.lastFrameRecomposited)

        // And a fill through the tools, which notes the change itself
        renderer.clearInsideSelection(path: CGPath(rect: CGRect(x: 0, y: 0, width: 64, height: 128), transform: nil),
                                      layer: harness.drawingLayer, context: harness.context)
        harness.renderFrameAsTheAppWould()
        XCTAssertTrue(renderer.lastFrameRecomposited, "after a tool wrote pixels")
        let composite = harness.pixels(of: renderer.compositeTexture)
        XCTAssertEqual(composite.at(x: 30, y: 64).x, 1, accuracy: 0.01, "and the picture is current: white paper where the stroke was cleared")
        XCTAssertLessThan(composite.at(x: 100, y: 64).x, 0.6, "the stroke (on the layer at 50%) still there beyond the clearing")
    }
}
