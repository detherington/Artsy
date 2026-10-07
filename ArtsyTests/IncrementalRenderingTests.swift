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

    private static let dualTipBrush: BrushDescriptor = {
        var brush = BrushDescriptor(copying: .softRound, id: UUID(), name: "Dual")
        var settings = StampSettings(spacing: 0.12, flow: 0.6)
        settings.secondTip = .init(tip: .bristle, scale: 0.7, angleJitter: 1)
        brush.rendering = .stamp(settings)
        return brush
    }()

    func testResultDoesNotDependOnHowSamplesFallIntoFrames() throws {
        let cases: [(BrushDescriptor, SymmetryMode)] = [
            (.softRound, .off), (.inkBrush, .radial(5)), (.oil, .quad), (.calligraphy, .off), (.eraser, .horizontal),
            // Stamp brushes: plain dabs, grain with jitter, a textured tip with scatter, a second tip
            (.airbrush, .quad), (.pencil, .off), (.chalk, .radial(3)), (Self.dualTipBrush, .horizontal),
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
            // Where symmetry copies of a stamp stroke overlap, the order their dabs blend in
            // depends on the framing; in a half-float texture that is worth a rounding step
            // or two, hence 2/255 rather than 1/255.
            for other in results.dropFirst() {
                XCTAssertLessThan(worstDifference(results[0], other), 0.008, "\(brush.name), \(symmetry.displayName)")
            }
        }
    }

    /// Mid-stroke, the regions recomposited frame by frame must add up to what a full
    /// recomposite of the same scene gives — with blend-mode layers, and with plain
    /// semi-transparent ones, where compositing any pixel twice would show.
    func testPartialCompositeMatchesFullComposite() throws {
        for blended in [true, false] {
            for brush in [BrushDescriptor.inkBrush, .softRound, .chalk, .eraser] {
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
        for brush in [BrushDescriptor.softRound, .marker, .pencil, .airbrush, .eraser] {
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

    /// While the pen is down only the stroke's rectangles are rebuilt — unless a tool wrote
    /// pixels meanwhile (a fill finishing in the background), which must show at once.
    func testPixelsAToolWritesMidStrokeShowBeforeThePenLifts() throws {
        let harness = try EngineHarness(width: 128, height: 128)
        let viewModel = harness.viewModel, renderer = harness.renderer
        let points = StrokeFixtures.line(from: CGPoint(x: 10, y: 20), to: CGPoint(x: 118, y: 20))
        renderer.beginStroke()
        viewModel.beginStroke(point: points[0])
        for point in points.dropFirst().prefix(10) { viewModel.continueStroke(point: point) }
        harness.renderFrameAsTheAppWould()
        harness.renderFrameAsTheAppWould()   // stroke-only frames from here on
        XCTAssertEqual(harness.composite().at(x: 64, y: 100).x, 1, accuracy: 0.01, "white paper away from the stroke")

        harness.fill(harness.backgroundLayer, red: 0, green: 0, blue: 1)
        viewModel.noteContentChanged()
        harness.renderFrameAsTheAppWould()
        XCTAssertEqual(harness.composite().at(x: 64, y: 100).z, 1, accuracy: 0.01, "shown before pen-up")
        XCTAssertEqual(harness.composite().at(x: 64, y: 100).x, 0, accuracy: 0.01)
        renderer.finalizeStroke()
        viewModel.endStroke()
    }

    /// The frame after pen-up recomposites where the stroke was, not the whole canvas, and
    /// the result is what a whole recomposite gives. A change to the scene still redoes it all.
    func testPenUpRecompositesOnlyWhereTheStrokeWas() throws {
        let harness = try EngineHarness(width: 256, height: 256)
        let renderer = harness.renderer
        configure(harness, brush: .inkBrush)
        harness.renderFrameAsTheAppWould()
        harness.draw(StrokeFixtures.line(from: CGPoint(x: 20, y: 60), to: CGPoint(x: 100, y: 60)))

        harness.renderFrameAsTheAppWould()
        XCTAssertTrue(renderer.lastFrameRecomposited)
        let regions = try XCTUnwrap(renderer.lastFrameRegions, "not all of it")
        let right = regions.map { $0.x + $0.width }.max() ?? 0, bottom = regions.map { $0.y + $0.height }.max() ?? 0
        XCTAssertLessThan(right, 130, "only around the stroke: \(regions)")
        XCTAssertLessThan(bottom, 256 - 40)
        let patched = harness.pixels(of: renderer.compositeTexture)
        harness.renderFrameAsTheAppWould()
        XCTAssertFalse(renderer.lastFrameRecomposited, "and then nothing more")

        harness.renderFrame()
        XCTAssertNil(renderer.lastFrameRegions, "a frame told to start over does all of it")
        XCTAssertEqual(worstDifference(patched, harness.pixels(of: renderer.compositeTexture)), 0, "to the same picture")

        harness.drawingLayer.opacity = 0.5
        harness.renderFrameAsTheAppWould()
        XCTAssertNil(renderer.lastFrameRegions, "a layer setting changes the whole picture")
    }

    /// The composite keeps smaller copies of itself for showing the canvas zoomed out, each
    /// level a 2×2 box of the one above, kept up to date where the composite changes.
    func testTheCompositesSmallerLevelsFollowIt() throws {
        let harness = try EngineHarness(width: 256, height: 128)
        let renderer = harness.renderer
        XCTAssertEqual(renderer.compositeTexture.mipmapLevelCount, 6, "down to 8×4")
        configure(harness, brush: .softRound)
        harness.renderFrameAsTheAppWould()

        func check(_ what: String) {
            for level in 1..<renderer.compositeTexture.mipmapLevelCount {
                let above = harness.pixels(of: renderer.compositeTexture, level: level - 1)
                let below = harness.pixels(of: renderer.compositeTexture, level: level)
                var worst: Float = 0
                for y in 0..<below.height {
                    for x in 0..<below.width {
                        let expected = (above.at(x: 2 * x, y: 2 * y) + above.at(x: 2 * x + 1, y: 2 * y)
                                        + above.at(x: 2 * x, y: 2 * y + 1) + above.at(x: 2 * x + 1, y: 2 * y + 1)) / 4
                        let got = below.at(x: x, y: y)
                        worst = max(worst, abs(expected.x - got.x), abs(expected.y - got.y), abs(expected.z - got.z), abs(expected.w - got.w))
                    }
                }
                XCTAssertLessThan(worst, 0.002, "level \(level) \(what)")
            }
        }
        check("after the first frame")
        XCTAssertGreaterThan(harness.pixels(of: renderer.compositeTexture, level: 3).at(x: 10, y: 5).w, 0.99, "paper everywhere")

        // A stroke brings the levels along where it lands, and only there is redone
        harness.draw(StrokeFixtures.line(from: CGPoint(x: 30, y: 60), to: CGPoint(x: 120, y: 70)))
        harness.renderFrameAsTheAppWould()
        XCTAssertNotNil(renderer.lastFrameRegions)
        check("after a stroke")
        XCTAssertLessThan(harness.pixels(of: renderer.compositeTexture, level: 2).at(x: 18, y: 16).x, 0.9, "the stroke, a quarter size")
    }
}
