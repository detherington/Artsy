import XCTest
import Metal
@testable import Artsy

/// A stroke is drawn piece by piece as samples arrive, and only the pixels it touched are
/// recomposited each frame. None of that may show: the result has to be the same however
/// the samples happen to be split across frames.
final class IncrementalRenderingTests: XCTestCase {
    private func worstDifference(_ a: PixelGrid, _ b: PixelGrid) -> Float {
        var worst: Float = 0
        for i in a.values.indices { worst = max(worst, abs(a.values[i] - b.values[i])) }
        return worst
    }

    private func configure(_ harness: EngineHarness, brush: BrushDescriptor, symmetry: SymmetryMode = .off) {
        harness.select(brush)
        harness.viewModel.currentColor = StrokeColor(red: 0.7, green: 0.2, blue: 0.3, alpha: 1)
        harness.viewModel.brushOpacity = 0.7
        harness.viewModel.symmetryMode = symmetry
    }

    func testResultDoesNotDependOnHowSamplesFallIntoFrames() throws {
        let cases: [(BrushDescriptor, SymmetryMode)] = [
            (.softRound, .off), (.inkBrush, .radial(5)), (.oil, .quad), (.calligraphy, .off), (.eraser, .horizontal),
        ]
        for (brush, symmetry) in cases {
            var results: [PixelGrid] = []
            for pointsPerFrame in [1, 3, 7, Int.max] {
                let harness = try EngineHarness(width: 256, height: 256)
                harness.fill(harness.drawingLayer, red: 0.2, green: 0.5, blue: 0.9, alpha: 0.8)
                configure(harness, brush: brush, symmetry: symmetry)
                harness.draw(StrokeFixtures.spiral(center: CGPoint(x: 150, y: 140), radius: 4...70, turns: 2.5),
                             pointsPerFrame: pointsPerFrame)
                harness.draw(StrokeFixtures.zigzag(from: CGPoint(x: 20, y: 30), length: 200, height: 50, teeth: 6),
                             pointsPerFrame: pointsPerFrame)
                results.append(harness.composite())
            }
            for other in results.dropFirst() {
                XCTAssertLessThan(worstDifference(results[0], other), 0.004, "\(brush.name), \(symmetry.displayName)")
            }
        }
    }

    /// Mid-stroke, the regions recomposited frame by frame must add up to what a full
    /// recomposite of the same scene gives — with blend-mode layers, and with plain
    /// semi-transparent ones, where compositing any pixel twice would show.
    func testPartialCompositeMatchesFullComposite() throws {
        for blended in [true, false] {
            for brush in [BrushDescriptor.softRound, .eraser] {
                let harness = try EngineHarness(width: 256, height: 256)
                harness.fill(harness.backgroundLayer, red: 0.9, green: 0.9, blue: 0.8, alpha: 0.7)
                harness.fill(harness.drawingLayer, red: 0.2, green: 0.5, blue: 0.9, alpha: 0.8)
                let upper = try harness.addLayer(blendMode: blended ? .multiply : .normal, opacity: 0.6)
                harness.fill(upper, red: 0.9, green: 0.8, blue: 0.3, alpha: 0.5)
                harness.layerStack.activeLayerIndex = 1
                harness.drawingLayer.blendMode = blended ? .screen : .normal
                harness.drawingLayer.opacity = 0.75
                configure(harness, brush: brush, symmetry: .radial(3))

                let points = StrokeFixtures.spiral(center: CGPoint(x: 150, y: 140), radius: 4...70, turns: 2.5)
                harness.renderer.beginStroke()
                harness.viewModel.beginStroke(point: points[0])
                for point in points.dropFirst() {
                    harness.viewModel.continueStroke(point: point)
                    harness.renderFrame()
                }
                let incremental = harness.composite()

                // Hiding and showing a layer changes the scene, which forces full recomposites.
                upper.isVisible = false
                harness.renderFrame()
                upper.isVisible = true
                let full = harness.composite()

                XCTAssertLessThan(worstDifference(incremental, full), 0.004,
                                  "\(brush.name), \(blended ? "blend modes" : "normal layers")")
                harness.renderer.finalizeStroke()
                harness.viewModel.endStroke()
            }
        }
    }

    /// The stroke is previewed inside its layer, so pen-up changes nothing on screen even
    /// when that layer has reduced opacity or a blend mode.
    func testPreviewMatchesTheMergedStrokeOnABlendedLayer() throws {
        for brush in [BrushDescriptor.softRound, .marker, .eraser] {
            let harness = try EngineHarness(width: 256, height: 256)
            harness.fill(harness.backgroundLayer, red: 0.9, green: 0.85, blue: 0.6)
            harness.fill(harness.drawingLayer, red: 0.2, green: 0.5, blue: 0.9, alpha: 0.8)
            harness.drawingLayer.blendMode = .multiply
            harness.drawingLayer.opacity = 0.6
            configure(harness, brush: brush)

            let points = StrokeFixtures.wave(from: CGPoint(x: 20, y: 128), length: 216, amplitude: 60, cycles: 2)
            harness.renderer.beginStroke()
            harness.viewModel.beginStroke(point: points[0])
            for (index, point) in points.dropFirst().enumerated() {
                harness.viewModel.continueStroke(point: point)
                if index % 4 == 0 { harness.renderFrame() }
            }
            let during = harness.composite()
            harness.renderer.finalizeStroke()
            harness.viewModel.endStroke()
            let after = harness.composite()

            XCTAssertLessThan(worstDifference(during, after), 0.004, brush.name)
        }
    }

    /// Changing the scene while the pen is down (layer opacity here) must not leave stale pixels.
    func testSceneChangeDuringAStrokeRecompositesEverything() throws {
        let harness = try EngineHarness(width: 200, height: 120)
        harness.fill(harness.backgroundLayer, red: 0, green: 0, blue: 0)
        harness.fill(harness.drawingLayer, red: 1, green: 1, blue: 1)
        let points = StrokeFixtures.line(from: CGPoint(x: 20, y: 60), to: CGPoint(x: 180, y: 60))
        harness.renderer.beginStroke()
        harness.viewModel.beginStroke(point: points[0])
        points.dropFirst().prefix(20).forEach(harness.viewModel.continueStroke(point:))
        harness.renderFrame()

        harness.drawingLayer.opacity = 0.5
        harness.viewModel.continueStroke(point: points[30])
        XCTAssertEqual(harness.composite().at(x: 190, y: 110).x, 0.5, accuracy: 0.01, "far from the stroke")
        harness.renderer.finalizeStroke()
        harness.viewModel.endStroke()
    }

    /// A stroke that never gets finalized must not leak into the next one.
    func testAbandonedStrokeLeavesNothingBehind() throws {
        let harness = try EngineHarness(width: 200, height: 120)
        harness.viewModel.brushSize = 30
        let abandoned = StrokeFixtures.line(from: CGPoint(x: 20, y: 90), to: CGPoint(x: 180, y: 90), pressure: 1...1)
        harness.renderer.beginStroke()
        harness.viewModel.beginStroke(point: abandoned[0])
        abandoned.dropFirst().forEach(harness.viewModel.continueStroke(point:))
        harness.renderFrame()
        harness.viewModel.endStroke()   // no finalizeStroke()

        harness.draw(StrokeFixtures.line(from: CGPoint(x: 20, y: 30), to: CGPoint(x: 180, y: 30), pressure: 1...1))
        let shown = harness.displayed()
        XCTAssertEqual(shown.at(x: 100, y: 90).x, 1, accuracy: 0.01, "the abandoned stroke")
        XCTAssertLessThan(shown.at(x: 100, y: 30).x, 0.05, "the stroke that was finished")
    }

    func testOverlappingRegionsAreMergedBeforeCompositing() {
        func rect(_ x: Int, _ y: Int, _ w: Int, _ h: Int) -> MTLScissorRect { MTLScissorRect(x: x, y: y, width: w, height: h) }
        let merged = CanvasRenderer.disjoint([rect(0, 0, 10, 10), rect(100, 100, 10, 10), rect(5, 5, 10, 10),
                                              rect(14, 14, 4, 4), rect(200, 0, 5, 5)])
        XCTAssertEqual(merged.count, 3)
        XCTAssertTrue(merged.contains { $0.x == 0 && $0.y == 0 && $0.width == 18 && $0.height == 18 })
        for (i, a) in merged.enumerated() {
            for b in merged.dropFirst(i + 1) {
                XCTAssertFalse(a.x < b.x + b.width && b.x < a.x + a.width && a.y < b.y + b.height && b.y < a.y + a.height)
            }
        }
    }
}
