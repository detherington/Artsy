import XCTest
@testable import Artsy

/// Water that moves: a wash spreads, runs with the tilt, settles its pigment as it dries
/// — darkest at the edges, more in the paper's valleys — and a wet stroke into it shoves
/// the pigment out.
final class WaterTests: XCTestCase {
    private let blue = StrokeColor(red: 0.05, green: 0.1, blue: 0.8, alpha: 1)

    /// Watercolor with its water settings replaced.
    private func wash(amount: Float = 0.6, flow: Float = 0.5, settling: Float = 0.4, granulation: Float = 0.5) -> BrushDescriptor {
        var brush = BrushDescriptor.watercolor
        brush.water = BrushDescriptor.Water(amount: amount, flow: flow, settling: settling, granulation: granulation)
        return brush
    }

    /// A canvas with one wash across the middle, the water still on it.
    private func canvasWithAWash(_ brush: BrushDescriptor, width: Int = 240, height: Int = 140, size: Float = 50) throws -> EngineHarness {
        let harness = try EngineHarness(width: width, height: height)
        harness.dryingTime = 10
        harness.select(brush)
        harness.viewModel.brushSize = size
        harness.viewModel.currentColor = blue
        harness.draw(StrokeFixtures.line(from: CGPoint(x: 40, y: 70), to: CGPoint(x: 200, y: 70), pressure: 1...1))
        return harness
    }

    private func alpha(_ harness: EngineHarness, _ x: Int, _ y: Int) -> Float {
        harness.pixels(of: harness.drawingLayer.texture).at(x: x, y: y).w
    }

    private func totalPigment(_ harness: EngineHarness) -> Float {
        let grid = harness.pixels(of: harness.drawingLayer.texture)
        return stride(from: 3, to: grid.values.count, by: 4).reduce(0) { $0 + grid.values[$1] }
    }

    // MARK: - Flow

    func testAStrokeLaysWaterThatSpreadsBeyondItAndDriesOff() throws {
        // A wet, free-flowing wash with time to spread before it dries
        let harness = try canvasWithAWash(wash(amount: 1, flow: 1))
        harness.dryingTime = 20
        XCTAssertNotNil(harness.drawingLayer.water, "water on the layer")
        let laid = harness.water(of: harness.drawingLayer).water
        XCTAssertGreaterThan(laid.at(x: 120, y: 70).x, 0.3, "water under the stroke: \(laid.at(x: 120, y: 70).x)")
        XCTAssertEqual(laid.at(x: 120, y: 110).x, 0, "none 40 px out")

        harness.letWaterRun(seconds: 6)
        let spread = harness.water(of: harness.drawingLayer).water
        // The soft stroke's own coverage ends about 25 px out; 30 px out is paper
        let outward = (95...115).map { String(format: "%.3f", spread.at(x: 120, y: $0).y) }.joined(separator: " ")
        XCTAssertGreaterThan(spread.at(x: 120, y: 100).y, 0.5, "the paper is wet 30 px out; soaked from 25 px: \(outward)")
        XCTAssertGreaterThan(alpha(harness, 120, 100), 0.005, "and some pigment has come with it: \(alpha(harness, 120, 100))")
        XCTAssertLessThan(spread.at(x: 120, y: 70).x, laid.at(x: 120, y: 70).x, "and the middle has thinned")

        harness.letWaterRun(seconds: 70)
        XCTAssertNil(harness.drawingLayer.water, "dry, and the water forgotten")
        let dried = harness.pixels(of: harness.drawingLayer.texture)
        harness.letWaterRun(seconds: 5)
        XCTAssertEqual(harness.pixels(of: harness.drawingLayer.texture).values, dried.values, "nothing moves once dry")
    }

    func testTheWaterCarriesThePigmentWithoutMakingOrLosingIt() throws {
        let still = try canvasWithAWash(wash(flow: 0.01, settling: 1))
        still.letWaterRun(seconds: 40)
        let moving = try canvasWithAWash(wash(flow: 0.8, settling: 0.2))
        moving.letWaterRun(seconds: 40)
        XCTAssertNil(moving.drawingLayer.water)
        XCTAssertEqual(totalPigment(moving), totalPigment(still), accuracy: totalPigment(still) * 0.08,
                       "the same pigment, moved: \(totalPigment(moving)) against \(totalPigment(still))")
    }

    func testPigmentRidesOutToTheEdgesAsTheWashDries() throws {
        func profile(flow: Float, settling: Float) throws -> [Float] {
            let harness = try canvasWithAWash(wash(flow: flow, settling: settling, granulation: 0))
            harness.letWaterRun(seconds: 40)
            let layer = harness.pixels(of: harness.drawingLayer.texture)
            // Outward from the middle of the stroke
            return (0...60).map { layer.at(x: 120, y: 70 + $0).w }
        }
        let flowing = try profile(flow: 0.6, settling: 0.3), still = try profile(flow: 0.01, settling: 1)
        func rim(_ profile: [Float]) -> Float {
            // The darkest band against the middle (the middle averaged, so one grain of the
            // paper does not decide it)
            profile.max()! / (profile[0...3].reduce(0, +) / 4)
        }
        let peakAt = flowing.firstIndex(of: flowing.max()!)!
        XCTAssertGreaterThan(rim(flowing), 1.15, "a darker rim than middle: \(flowing.map { String(format: "%.2f", $0) })")
        XCTAssertTrue((8...45).contains(peakAt), "out towards the edge, at \(peakAt) px")
        XCTAssertGreaterThan(rim(flowing), rim(still) * 1.1, "the more the water moves, the stronger the rim: \(rim(flowing)) against \(rim(still))")
    }

    func testMorePigmentSettlesInThePapersValleys() throws {
        func valleysAgainstPeaks(granulation: Float) throws -> Float {
            let harness = try canvasWithAWash(wash(flow: 0.3, settling: 0.4, granulation: granulation))
            harness.letWaterRun(seconds: 40)
            let layer = harness.pixels(of: harness.drawingLayer.texture)
            let paper = BrushTextureLibrary.paperGrainPixels(), size = BrushTextureLibrary.grainSize
            var valleys: [Float] = [], peaks: [Float] = []
            // Well inside the stroke; the paper is fixed to the canvas, origin bottom-left
            for y in 55...85 { for x in 60...180 {
                // The water reads the paper at 0.4 texels per pixel (WaterRenderer)
                let px = Int((Float(x) * 0.4).rounded(.down)) % size, py = Int((Float(y) * 0.4).rounded(.down)) % size
                let h = Float(paper[py * size + px]) / 255
                if h < 0.25 { valleys.append(layer.at(x: x, y: y).w) } else if h > 0.75 { peaks.append(layer.at(x: x, y: y).w) }
            } }
            return valleys.reduce(0, +) / Float(valleys.count) / (peaks.reduce(0, +) / Float(peaks.count))
        }
        let grainy = try valleysAgainstPeaks(granulation: 1), smooth = try valleysAgainstPeaks(granulation: 0)
        XCTAssertGreaterThan(grainy, smooth * 1.05, "valleys darker with granulation: \(grainy) against \(smooth)")
        XCTAssertEqual(smooth, 1, accuracy: 0.08, "and even without")
    }

    func testTheWashRunsDownhillWithTheTilt() throws {
        func centroidX(tilt: Float) throws -> Float {
            let harness = try canvasWithAWash(wash(flow: 0.6, settling: 0.3), width: 300, height: 140, size: 40)
            harness.renderer.tiltOverride = SIMD2(tilt, 0)
            harness.letWaterRun(seconds: 40)
            let layer = harness.pixels(of: harness.drawingLayer.texture)
            var sum: Float = 0, weight: Float = 0
            for y in 0..<140 { for x in 0..<300 { let a = layer.at(x: x, y: y).w; sum += a * Float(x); weight += a } }
            return sum / weight
        }
        let level = try centroidX(tilt: 0), tilted = try centroidX(tilt: 1)
        XCTAssertGreaterThan(tilted, level + 3, "the pigment has run to the right: \(tilted) against \(level)")
    }

    func testCleanWaterIntoADryingWashShovesItsPigmentOut() throws {
        func middle(withWater: Bool) throws -> Float {
            let harness = try canvasWithAWash(wash(flow: 0.5, settling: 0.3), size: 60)
            harness.letWaterRun(seconds: 3)
            if withWater {
                harness.select(.water)
                harness.viewModel.brushSize = 30
                harness.draw(StrokeFixtures.line(from: CGPoint(x: 118, y: 70), to: CGPoint(x: 122, y: 70), pressure: 1...1))
            }
            harness.letWaterRun(seconds: 40)
            return (-4...4).reduce(0) { $0 + alpha(harness, 120 + $1, 70) } / 9
        }
        let plain = try middle(withWater: false), bloomed = try middle(withWater: true)
        XCTAssertLessThan(bloomed, plain * 0.85, "lighter where the water landed: \(bloomed) against \(plain)")
    }

    // MARK: - Living with the rest

    func testUndoDuringTheFlowPutsTheLayerBackAndStopsIt() throws {
        let harness = try EngineHarness(width: 240, height: 140)
        harness.dryingTime = 10
        harness.select(.hardRound)
        harness.viewModel.currentColor = StrokeColor(red: 0.9, green: 0.2, blue: 0.1, alpha: 1)
        harness.draw(StrokeFixtures.line(from: CGPoint(x: 40, y: 40), to: CGPoint(x: 200, y: 40), pressure: 1...1))
        let before = harness.pixels(of: harness.drawingLayer.texture)
        harness.select(wash())
        harness.viewModel.brushSize = 50
        harness.viewModel.currentColor = blue
        harness.draw(StrokeFixtures.line(from: CGPoint(x: 40, y: 70), to: CGPoint(x: 200, y: 70), pressure: 1...1))
        harness.letWaterRun(seconds: 2)
        XCTAssertNotNil(harness.drawingLayer.water)
        harness.viewModel.performUndo(renderer: harness.renderer)
        harness.renderFrame()
        XCTAssertNil(harness.drawingLayer.water, "the flow has stopped")
        XCTAssertEqual(harness.pixels(of: harness.drawingLayer.texture).values, before.values, "and the layer is as it was")
    }

    func testAnotherBrushOnTheLayerSettlesTheWaterAndStays() throws {
        let harness = try canvasWithAWash(wash())
        harness.letWaterRun(seconds: 1)
        harness.select(.hardRound)
        harness.viewModel.brushSize = 20
        harness.viewModel.currentColor = StrokeColor(red: 0.9, green: 0.2, blue: 0.1, alpha: 1)
        harness.draw(StrokeFixtures.line(from: CGPoint(x: 120, y: 20), to: CGPoint(x: 120, y: 120), pressure: 1...1))
        XCTAssertNil(harness.drawingLayer.water, "the water stopped at pen-down")
        let red = harness.pixels(of: harness.drawingLayer.texture).at(x: 120, y: 110)
        XCTAssertGreaterThan(red.x / max(red.w, 0.001), 0.8, "the ink is there: \(red)")
        harness.letWaterRun(seconds: 5)
        XCTAssertEqual(harness.pixels(of: harness.drawingLayer.texture).at(x: 120, y: 110), red, "and stays")
    }

    func testDryLayerStopsTheWaterWhereItIs() throws {
        let harness = try canvasWithAWash(wash())
        harness.letWaterRun(seconds: 1)
        let look = harness.pixels(of: harness.drawingLayer.texture)
        harness.viewModel.dryActiveLayer()
        XCTAssertNil(harness.drawingLayer.water)
        harness.letWaterRun(seconds: 5)
        XCTAssertEqual(harness.pixels(of: harness.drawingLayer.texture).values, look.values)
    }

    func testWaterSettingsSurviveTheBrushFileAndOldFilesHaveNone() throws {
        var brush = BrushDescriptor.watercolor
        brush.water = BrushDescriptor.Water(amount: 0.3, flow: 0.9, settling: 0.1, granulation: 0.7)
        let back = try JSONDecoder().decode(BrushDescriptor.self, from: JSONEncoder().encode(brush))
        XCTAssertEqual(back.water, brush.water)
        var json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(brush)) as! [String: Any]
        json["water"] = nil
        let old = try JSONDecoder().decode(BrushDescriptor.self, from: JSONSerialization.data(withJSONObject: json))
        XCTAssertNil(old.water)
    }
}


