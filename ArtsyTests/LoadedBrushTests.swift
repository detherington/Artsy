import XCTest
#if canImport(Artsy)
@testable import Artsy
#endif
@testable import ArtsyEngine

/// A loaded brush: paint that runs out along a stroke, picks up what it crosses, and comes
/// back to its own colour.
final class LoadedBrushTests: XCTestCase {
    private let red = StrokeColor(red: 1, green: 0, blue: 0, alpha: 1)
    private let blue = StrokeColor(red: 0, green: 0, blue: 1, alpha: 1)

    /// A round, opaque, grainless loaded brush mixing light, so the numbers read plainly.
    private func loaded(_ harness: EngineHarness, amount: Float = 1, depletion: Float = 0, resaturation: Float = 0,
                        bleed: Float = 0, variation: Float = 0, size: Float = 40) {
        var brush = BrushDescriptor(copying: .hardRound, id: UUID(), name: "Loaded")
        var settings = StampSettings(spacing: 0.1, flow: 0.6)
        settings.load = .init(amount: amount, depletion: depletion, resaturation: resaturation, bleed: bleed, variation: variation)
        brush.rendering = .stamp(settings)
        brush.mixing = .light
        brush.opacity = 1
        harness.select(brush)
        harness.viewModel.brushSize = size
        harness.viewModel.brushOpacity = 1
    }

    /// The straight colour of a layer pixel.
    private func colour(_ p: SIMD4<Float>) -> SIMD3<Float> {
        p.w > 0.001 ? SIMD3(p.x, p.y, p.z) / p.w : .zero
    }

    /// A canvas with a solid red block of wet paint on the left, ending at x ≈ 110.
    private func canvasWithRedBlock() throws -> EngineHarness {
        let harness = try EngineHarness(width: 320, height: 120)
        var fresh = BrushDescriptor.hardRound
        fresh.wetness = 1
        harness.select(fresh)
        harness.viewModel.brushSize = 100
        harness.viewModel.currentColor = red
        harness.draw(StrokeFixtures.line(from: CGPoint(x: 10, y: 60), to: CGPoint(x: 60, y: 60), pressure: 1...1))
        XCTAssertEqual(harness.pixels(of: harness.drawingLayer.texture).at(x: 100, y: 60).w, 1, accuracy: 0.01)
        return harness
    }

    func testTheBrushRunsOutAlongAStroke() throws {
        for depletion: Float in [0, 0.6] {
            let harness = try EngineHarness(width: 480, height: 120)
            loaded(harness, depletion: depletion)
            harness.viewModel.currentColor = blue
            harness.draw(StrokeFixtures.line(from: CGPoint(x: 30, y: 60), to: CGPoint(x: 450, y: 60), pressure: 1...1))
            let layer = harness.pixels(of: harness.drawingLayer.texture)
            let start = layer.at(x: 60, y: 60).w, end = layer.at(x: 420, y: 60).w
            XCTAssertGreaterThan(start, 0.9, "full at the start (depletion \(depletion))")
            if depletion == 0 {
                XCTAssertGreaterThan(end, 0.9, "and never runs out")
            } else {
                XCTAssertLessThan(end, 0.15, "ten diameters on, the brush is nearly dry")
                XCTAssertLessThan(layer.at(x: 250, y: 60).w, start, "running out as it goes")
                XCTAssertGreaterThan(layer.at(x: 250, y: 60).w, end)
            }
        }
    }

    func testPaintCrossedComesAlongInTheTail() throws {
        for bleed: Float in [0, 0.8] {
            let harness = try canvasWithRedBlock()
            loaded(harness, depletion: 0.05, bleed: bleed)
            harness.viewModel.currentColor = blue
            harness.draw(StrokeFixtures.line(from: CGPoint(x: 70, y: 60), to: CGPoint(x: 300, y: 60), pressure: 1...1))
            let layer = harness.pixels(of: harness.drawingLayer.texture)
            let near = colour(layer.at(x: 150, y: 60)), far = colour(layer.at(x: 280, y: 60))
            if bleed == 0 {
                XCTAssertLessThan(near.x, 0.05, "nothing picked up: blue stays blue")
            } else {
                XCTAssertGreaterThan(near.x, 0.25, "red from the block, 40 px past it: \(near)")
                XCTAssertGreaterThan(near.z, 0.25, "in with the blue")
                XCTAssertEqual(far.x, near.x, accuracy: 0.03, "carried along the tail, with nothing to refill it: \(far)")
            }
        }
    }

    func testRefillingBringsTheBrushBackToItsColour() throws {
        var reds: [Float] = []
        for resaturation: Float in [0, 0.5] {
            let harness = try canvasWithRedBlock()
            loaded(harness, depletion: 0.05, resaturation: resaturation, bleed: 0.8)
            harness.viewModel.currentColor = blue
            harness.draw(StrokeFixtures.line(from: CGPoint(x: 70, y: 60), to: CGPoint(x: 300, y: 60), pressure: 1...1))
            reds.append(colour(harness.pixels(of: harness.drawingLayer.texture).at(x: 280, y: 60)).x)
        }
        XCTAssertLessThan(reds[1], reds[0] * 0.5, "with refilling the red has gone by the end: \(reds)")
        XCTAssertLessThan(reds[1], 0.1)
    }

    func testUnevenBristlesLeaveStreaksAsTheBrushRunsOut() throws {
        var spreads: [Float] = []
        for variation: Float in [0, 1] {
            let harness = try EngineHarness(width: 480, height: 120)
            loaded(harness, depletion: 0.15, variation: variation)
            harness.viewModel.currentColor = blue
            harness.draw(StrokeFixtures.line(from: CGPoint(x: 30, y: 60), to: CGPoint(x: 450, y: 60), pressure: 1...1))
            let layer = harness.pixels(of: harness.drawingLayer.texture)
            // Across the stroke's middle, half way along, relative to the most paint there
            let across = (50...70).map { layer.at(x: 300, y: $0).w }
            XCTAssertGreaterThan(across.max()!, 0.2, "still painting half way")
            spreads.append((across.max()! - across.min()!) / across.max()!)
        }
        XCTAssertLessThan(spreads[0], 0.25, "evenly loaded: even across the stroke: \(spreads)")
        XCTAssertGreaterThan(spreads[1], 0.5, "unevenly loaded: some bristles have run dry: \(spreads)")
    }

    /// Where the carry is brought up to date depends on the path, not on which frame a dab
    /// arrived in, so the stroke comes out the same however its samples fall into frames.
    func testTheResultDoesNotDependOnHowSamplesFallIntoFrames() throws {
        var results: [PixelGrid] = []
        for pointsPerFrame in [1, 7, Int.max] {
            let harness = try canvasWithRedBlock()
            loaded(harness, depletion: 0.2, resaturation: 0.1, bleed: 0.7, variation: 0.6)
            harness.viewModel.currentColor = blue
            harness.draw(StrokeFixtures.line(from: CGPoint(x: 70, y: 40), to: CGPoint(x: 300, y: 80), pressure: 0.4...1),
                         pointsPerFrame: pointsPerFrame)
            results.append(harness.pixels(of: harness.drawingLayer.texture))
        }
        for other in results.dropFirst() {
            var worst: Float = 0
            for i in results[0].values.indices { worst = max(worst, abs(results[0].values[i] - other.values[i])) }
            XCTAssertLessThan(worst, 0.01)
        }
    }
}
