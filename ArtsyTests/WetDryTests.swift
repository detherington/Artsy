import XCTest
#if canImport(Artsy)
@testable import Artsy
#endif
@testable import ArtsyEngine

/// Wet and dry: paint that stays wet for a while, a loaded brush that picks up only wet
/// paint, a wash that blends into wet paint and glazes dry paint, and drying on demand.
final class WetDryTests: XCTestCase {
    private let red = StrokeColor(red: 1, green: 0, blue: 0, alpha: 1)
    private let blue = StrokeColor(red: 0.05, green: 0.1, blue: 0.8, alpha: 1)
    private let yellow = StrokeColor(red: 0.95, green: 0.85, blue: 0.1, alpha: 1)

    /// Hard Round laying paint that stays wet for `wetness` of the drying time.
    private func fresh(wetness: Float) -> BrushDescriptor {
        var brush = BrushDescriptor.hardRound
        brush.wetness = wetness
        return brush
    }

    private func colour(_ p: SIMD4<Float>) -> SIMD3<Float> {
        p.w > 0.001 ? SIMD3(p.x, p.y, p.z) / p.w : .zero
    }

    // MARK: - Drying

    func testPaintStaysWetForTheBrushsShareOfTheDryingTimeThenDries() throws {
        let harness = try EngineHarness(width: 200, height: 100)
        harness.dryingTime = 10
        harness.select(fresh(wetness: 1))
        harness.viewModel.brushSize = 30
        harness.viewModel.currentColor = red
        harness.draw(StrokeFixtures.line(from: CGPoint(x: 20, y: 50), to: CGPoint(x: 180, y: 50), pressure: 1...1))
        func wet() -> Float { harness.wetness(of: harness.drawingLayer).at(x: 100, y: 50).x }
        XCTAssertEqual(wet(), 1, accuracy: 0.01, "wet as it is laid")
        XCTAssertEqual(harness.wetness(of: harness.drawingLayer).at(x: 100, y: 90).x, 0, "and not where nothing was painted")
        XCTAssertTrue(harness.drawingLayer.isWet(at: harness.clock.now))
        harness.advance(by: 4)
        XCTAssertEqual(wet(), 1, accuracy: 0.01, "still wet at 4 s of 10")
        harness.advance(by: 3.5)
        XCTAssertEqual(wet(), 0.5, accuracy: 0.05, "half dry at 7.5 s")
        harness.advance(by: 3)
        XCTAssertEqual(wet(), 0, "dry at 10.5 s")
        XCTAssertFalse(harness.drawingLayer.isWet(at: harness.clock.now))

        // A brush that dries fast is wet for its share
        harness.select(fresh(wetness: 0.4))
        harness.viewModel.brushSize = 30
        harness.draw(StrokeFixtures.line(from: CGPoint(x: 20, y: 50), to: CGPoint(x: 180, y: 50), pressure: 1...1))
        XCTAssertEqual(wet(), 0.8, accuracy: 0.05, "4 s of wetness over a 5 s drying-off")
        harness.advance(by: 4.5)
        XCTAssertEqual(wet(), 0, "dry")

        // Ordinary paint never wets the layer
        let dryCanvas = try EngineHarness(width: 100, height: 100)
        dryCanvas.select(.hardRound)
        dryCanvas.draw(StrokeFixtures.line(from: CGPoint(x: 20, y: 50), to: CGPoint(x: 80, y: 50), pressure: 1...1))
        XCTAssertNil(dryCanvas.drawingLayer.wetTexture)
    }

    func testDryLayerDriesAtOnce() throws {
        let harness = try EngineHarness(width: 200, height: 100)
        harness.select(.oil)
        harness.viewModel.currentColor = red
        harness.draw(StrokeFixtures.line(from: CGPoint(x: 20, y: 50), to: CGPoint(x: 180, y: 50), pressure: 1...1))
        XCTAssertGreaterThan(harness.wetness(of: harness.drawingLayer).at(x: 100, y: 50).x, 0.9)
        harness.viewModel.dryActiveLayer()
        XCTAssertEqual(harness.wetness(of: harness.drawingLayer).at(x: 100, y: 50).x, 0)
        XCTAssertFalse(harness.drawingLayer.isWet(at: harness.clock.now))
    }

    // MARK: - What wet paint does

    /// A loaded brush crossing red takes red along while the red is wet, not once it has dried,
    /// and never from paint that was never wet.
    func testALoadedBrushPicksUpWetPaintNotDry() throws {
        func redInTail(block: BrushDescriptor, after seconds: TimeInterval) throws -> Float {
            let harness = try EngineHarness(width: 320, height: 120)
            harness.dryingTime = 10
            harness.select(block)
            harness.viewModel.brushSize = 100
            harness.viewModel.currentColor = red
            harness.draw(StrokeFixtures.line(from: CGPoint(x: 10, y: 60), to: CGPoint(x: 60, y: 60), pressure: 1...1))
            harness.advance(by: seconds)
            harness.select(.oil)
            harness.viewModel.brushSize = 40
            harness.viewModel.currentColor = blue
            harness.draw(StrokeFixtures.line(from: CGPoint(x: 40, y: 60), to: CGPoint(x: 300, y: 60), pressure: 1...1))
            return colour(harness.pixels(of: harness.drawingLayer.texture).at(x: 150, y: 60)).x
        }
        let wet = try redInTail(block: fresh(wetness: 1), after: 0)
        let dried = try redInTail(block: fresh(wetness: 1), after: 12)
        let neverWet = try redInTail(block: .hardRound, after: 0)
        XCTAssertGreaterThan(wet, 0.25, "red comes along from wet paint: \(wet)")
        XCTAssertLessThan(dried, wet * 0.3, "not once it has dried: \(dried)")
        XCTAssertLessThan(neverWet, wet * 0.3, "and not from ink: \(neverWet)")
    }

    /// A blue wash across a yellow one: into the wet yellow it blends to green with a soft
    /// edge; over the yellow once dry it glazes, darker, with a rim just inside its edge.
    func testAWashIntoWetPaintBlendsAndFeathersButGlazesDryPaint() throws {
        func crossing(after seconds: TimeInterval) throws -> (centre: SIMD3<Float>, profile: [Float]) {
            let harness = try EngineHarness(width: 240, height: 200)
            harness.dryingTime = 10
            var wash = BrushDescriptor.watercolor
            wash.wet = BrushDescriptor.Wet(edges: 0.8, granulation: 0, grainScale: 1, blendsWhenWet: 1)
            wash.water = nil   // the wash that dries at the merge
            harness.select(wash)
            harness.viewModel.brushSize = 120
            harness.viewModel.currentColor = yellow
            harness.draw(StrokeFixtures.line(from: CGPoint(x: 20, y: 100), to: CGPoint(x: 220, y: 100), pressure: 1...1))
            harness.advance(by: seconds)
            harness.viewModel.brushSize = 50
            harness.viewModel.currentColor = blue
            harness.draw(StrokeFixtures.line(from: CGPoint(x: 120, y: 10), to: CGPoint(x: 120, y: 190), pressure: 1...1))
            let layer = harness.pixels(of: harness.drawingLayer.texture)
            // Across the blue stroke, outward from its middle, inside the yellow
            let profile = (0...40).map { x -> Float in
                let p = layer.at(x: 120 + x, y: 100)
                return 1 - (p.x + p.y + p.z) / 3 / max(p.w, 0.001)   // darkness
            }
            return (colour(layer.at(x: 120, y: 100)), profile)
        }
        let wet = try crossing(after: 0), dry = try crossing(after: 12)
        // Blended as pigment, blue into yellow is a saturated green; the glaze over the
        // half-transparent yellow is a dull near-grey
        func saturation(_ c: SIMD3<Float>) -> Float { (c.max() - c.min()) / max(c.max(), 0.001) }
        XCTAssertGreaterThanOrEqual(wet.centre.y, wet.centre.z, "green, not blue: \(wet.centre)")
        XCTAssertGreaterThan(saturation(wet.centre), saturation(dry.centre) + 0.3,
                             "a mixed colour, not a dulled one: \(wet.centre) against \(dry.centre)")
        // The glaze gathers pigment at its edge; the wet one does not, and fades out soft
        let dryPeak = dry.profile.firstIndex(of: dry.profile.max()!)!
        XCTAssertGreaterThan(dryPeak, 5, "a rim near the dry edge, at \(dryPeak) px out")
        let wetPeak = wet.profile.firstIndex(of: wet.profile.max()!)!
        XCTAssertLessThan(wetPeak, 6, "no rim when wet: \(wet.profile.map { String(format: "%.2f", $0) })")
        func softPixels(_ profile: [Float]) -> Int {
            let middle = profile[0], floor = profile.last!
            return profile.filter { $0 > floor + 0.03 && $0 < floor + (middle - floor) * 0.5 }.count
        }
        XCTAssertGreaterThan(softPixels(wet.profile), softPixels(dry.profile) * 2,
                             "a softer edge when wet: \(softPixels(wet.profile)) vs \(softPixels(dry.profile)) soft px")
    }

    // MARK: - Undo, display

    func testUndoPutsBackHowWetThePaintWas() throws {
        let harness = try EngineHarness(width: 200, height: 100)
        harness.dryingTime = 10
        harness.select(fresh(wetness: 0.5))
        harness.viewModel.brushSize = 30
        harness.viewModel.currentColor = red
        harness.draw(StrokeFixtures.line(from: CGPoint(x: 20, y: 50), to: CGPoint(x: 180, y: 50), pressure: 1...1))
        harness.advance(by: 2)
        let before = harness.wetness(of: harness.drawingLayer)
        harness.select(fresh(wetness: 1))
        harness.viewModel.brushSize = 30
        harness.draw(StrokeFixtures.line(from: CGPoint(x: 20, y: 50), to: CGPoint(x: 180, y: 50), pressure: 1...1))
        XCTAssertGreaterThan(harness.wetness(of: harness.drawingLayer).at(x: 100, y: 50).x, before.at(x: 100, y: 50).x + 0.3,
                             "the second stroke wets it afresh")
        harness.viewModel.performUndo(renderer: harness.renderer)
        let after = harness.wetness(of: harness.drawingLayer)
        for x in stride(from: 10, to: 190, by: 20) {
            XCTAssertEqual(after.at(x: x, y: 50).x, before.at(x: x, y: 50).x, accuracy: 0.02, "at x=\(x)")
        }
        // Undoing the first stroke, the only thing that ever wetted the layer, dries it
        harness.viewModel.performUndo(renderer: harness.renderer)
        XCTAssertEqual(harness.wetness(of: harness.drawingLayer).at(x: 100, y: 50).x, 0)
    }

    func testShowingWetPaintTintsItUntilItDries() throws {
        let harness = try EngineHarness(width: 200, height: 100)
        harness.dryingTime = 10
        harness.select(fresh(wetness: 1))
        harness.viewModel.brushSize = 30
        harness.viewModel.currentColor = red
        harness.draw(StrokeFixtures.line(from: CGPoint(x: 20, y: 50), to: CGPoint(x: 180, y: 50), pressure: 1...1))
        let plain = harness.shown(relief: 0).at(x: 100, y: 50)
        let shownWet = harness.shown(relief: 0, showWet: true).at(x: 100, y: 50)
        XCTAssertGreaterThan(shownWet.z, plain.z + 0.1, "bluer where wet: \(shownWet) against \(plain)")
        XCTAssertEqual(harness.shown(relief: 0, showWet: true).at(x: 100, y: 90), harness.shown(relief: 0).at(x: 100, y: 90), "paper as it was")
        harness.advance(by: 12)
        XCTAssertEqual(harness.shown(relief: 0, showWet: true).at(x: 100, y: 50), plain, "nothing to show once dry")
    }

    func testWetSettingsSurviveTheBrushFile() throws {
        var brush = BrushDescriptor.watercolor
        brush.wetness = 0.7
        brush.wet = BrushDescriptor.Wet(edges: 0.5, granulation: 0.2, grainScale: 2, blendsWhenWet: 0.3)
        let data = try JSONEncoder().encode(brush)
        let back = try JSONDecoder().decode(BrushDescriptor.self, from: data)
        XCTAssertEqual(back.wetness, 0.7)
        XCTAssertEqual(back.wet?.blendsWhenWet, 0.3)
        // A file from before wetness: dry at once, and a wash that blends fully
        var json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(brush)) as! [String: Any]
        json["wetness"] = nil
        var wet = json["wet"] as! [String: Any]
        wet["blendsWhenWet"] = nil
        json["wet"] = wet
        let old = try JSONDecoder().decode(BrushDescriptor.self, from: JSONSerialization.data(withJSONObject: json))
        XCTAssertEqual(old.wetness, 0)
        XCTAssertEqual(old.wet?.blendsWhenWet, 1)
    }
}
