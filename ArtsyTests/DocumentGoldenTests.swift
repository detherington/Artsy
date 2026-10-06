import XCTest
@testable import Artsy

/// A document using every feature, saved and loaded, rendered the way the display shows it.
/// Protects the file format and the whole render path at once.
final class DocumentGoldenTests: XCTestCase {
    private func worst(_ a: PixelGrid, _ b: PixelGrid) -> Float {
        var worst: Float = 0
        for i in a.values.indices { worst = max(worst, abs(a.values[i] - b.values[i])) }
        return worst
    }

    func testTheEverythingDocument() throws {
        let harness = try EngineHarness()
        let viewModel = harness.viewModel

        // Layer 1: a watercolor wash, oil over it, smudged
        harness.select(.watercolor)
        viewModel.brushSize = 50
        viewModel.currentColor = StrokeColor(red: 0.2, green: 0.5, blue: 0.85, alpha: 1)
        harness.draw(StrokeFixtures.wave(from: CGPoint(x: 30, y: 200), length: 450, amplitude: 30, cycles: 1.5))
        harness.select(.oil)
        viewModel.brushSize = 36
        viewModel.currentColor = StrokeColor(red: 0.9, green: 0.6, blue: 0.15, alpha: 1)
        harness.draw(StrokeFixtures.line(from: CGPoint(x: 40, y: 120), to: CGPoint(x: 470, y: 150), pressure: 0.4...1.0))
        harness.select(.smudge)
        viewModel.brushSize = 30
        harness.draw(StrokeFixtures.line(from: CGPoint(x: 250, y: 140), to: CGPoint(x: 290, y: 60), pressure: 1...1))

        // Layer 2, multiply at 80%: acrylic and a held rectangle
        let multiply = try harness.addLayer(blendMode: .multiply, opacity: 0.8)
        harness.select(.acrylic)
        viewModel.brushSize = 28
        viewModel.currentColor = StrokeColor(red: 0.3, green: 0.7, blue: 0.3, alpha: 1)
        harness.draw(StrokeFixtures.zigzag(from: CGPoint(x: 60, y: 40), length: 300, height: 60, teeth: 4))
        harness.select(.technicalPen)
        viewModel.brushSize = 5
        viewModel.currentColor = .black
        harness.draw(StrokeFixtures.held(StrokeFixtures.rough(StrokeFixtures.polygonPositions([
            CGPoint(x: 380, y: 40), CGPoint(x: 480, y: 45), CGPoint(x: 478, y: 110), CGPoint(x: 382, y: 105)
        ]), wobble: 5), for: 0.8))
        multiply.name = "Multiply"

        // A hidden layer with a stroke that must not show, guides, and a changed background
        let hidden = try harness.addLayer()
        harness.select(.marker)
        viewModel.currentColor = StrokeColor(red: 1, green: 0, blue: 1, alpha: 1)
        harness.draw(StrokeFixtures.line(from: CGPoint(x: 0, y: 0), to: CGPoint(x: 512, y: 288)))
        hidden.isVisible = false
        hidden.name = "Hidden"
        harness.fill(harness.backgroundLayer, red: 0.97, green: 0.95, blue: 0.9)
        viewModel.guides.verticals = [128]
        viewModel.guides.showsGrid = true

        let rendered = harness.shown(relief: 1)
        Golden.assertMatches(rendered, named: "everything-document")

        // Saved and loaded, it renders the same: layers are 8-bit on disk, thickness 16-bit
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("ArtsyEverything-\(UUID().uuidString).artsy")
        defer { try? FileManager.default.removeItem(at: url) }
        let saved = expectation(description: "saved")
        CanvasDocument.saveAsync(renderer: harness.renderer, viewModel: viewModel, to: url) { result in
            if case .failure(let error) = result { XCTFail("\(error)") }
            saved.fulfill()
        }
        wait(for: [saved], timeout: 10)
        let loaded = try CanvasDocument.load(from: url, metalContext: harness.context)
        XCTAssertEqual(loaded.viewModel.layerStack.layers.map(\.name), harness.layerStack.layers.map(\.name))
        XCTAssertEqual(loaded.viewModel.layerStack.layers.map(\.isVisible), [true, true, true, false])
        XCTAssertEqual(loaded.viewModel.layerStack.layers[2].blendMode, .multiply)
        XCTAssertEqual(loaded.viewModel.guides, viewModel.guides)
        XCTAssertNotNil(loaded.viewModel.layerStack.layers[1].heightTexture, "the oil's thickness came back")
        let reloaded = EngineHarness.shown(by: loaded.canvasView.renderer, relief: 1)
        XCTAssertLessThan(worst(rendered, reloaded), 0.02)
    }
}
