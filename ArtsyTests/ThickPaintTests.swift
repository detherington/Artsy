import XCTest
#if canImport(Artsy)
@testable import Artsy
#endif
@testable import ArtsyEngine

/// Thick paint pushed about: a dab moves the paint under it to its rim and ahead of it,
/// bristles cut grooves, the light reads the surface, and a knife does nothing but push.
final class ThickPaintTests: XCTestCase {
    private let ochre = StrokeColor(red: 0.85, green: 0.55, blue: 0.15, alpha: 1)

    /// A plain thick brush: round, hard, no load, no grain, so the height reads plainly.
    private func thick(_ harness: EngineHarness, thickness: Float = 0.1, squeeze: Float, grooves: Float = 0, size: Float = 40) {
        var brush = BrushDescriptor.hardRound
        brush.name = "Thick"
        var settings = StampSettings(spacing: 0.1, flow: 1)
        settings.impasto = .init(thickness: thickness, squeeze: squeeze, grooves: grooves)
        brush.rendering = .stamp(settings)
        brush.mixing = .light
        brush.opacity = 1
        harness.select(brush)
        harness.viewModel.brushSize = size
        harness.viewModel.brushOpacity = 1
        harness.viewModel.currentColor = ochre
    }

    private func total(_ grid: PixelGrid) -> Float {
        stride(from: 0, to: grid.values.count, by: 4).reduce(0) { $0 + grid.values[$1] }
    }

    func testAStrokeThroughThickPaintPloughsAFurrowAndRaisesARidge() throws {
        var results: [Float: (base: Float, crossing: Float, beside: Float)] = [:]
        for squeeze: Float in [0, 0.8] {
            let harness = try EngineHarness(width: 240, height: 240)
            thick(harness, squeeze: squeeze)
            harness.draw(StrokeFixtures.line(from: CGPoint(x: 20, y: 120), to: CGPoint(x: 220, y: 120), pressure: 1...1))
            let base = harness.heights(of: harness.drawingLayer).at(x: 60, y: 120).x
            harness.draw(StrokeFixtures.line(from: CGPoint(x: 120, y: 20), to: CGPoint(x: 120, y: 220), pressure: 1...1))
            let after = harness.heights(of: harness.drawingLayer)
            // Under the second stroke where it crosses the first, and on the first just
            // outside the second's edge (radius 20, the band beyond it)
            results[squeeze] = (base, after.at(x: 120, y: 120).x, after.at(x: 146, y: 120).x)
        }
        let plain = results[0]!, pushed = results[0.8]!
        XCTAssertEqual(plain.crossing, plain.base * 2, accuracy: plain.base * 0.15, "without pushing the heights add")
        XCTAssertEqual(plain.beside, plain.base, accuracy: plain.base * 0.15)
        XCTAssertGreaterThan(pushed.base, 0.05, "still thick: \(pushed)")
        XCTAssertLessThan(pushed.crossing, plain.crossing * 0.85, "a furrow: the first stroke's paint pushed out from under the second")
        XCTAssertGreaterThan(pushed.beside, pushed.base * 1.25, "and a ridge beside it: \(pushed)")
    }

    func testAStrokeEndsInARidgeOfPushedPaint() throws {
        var beyond: [Float] = []
        for squeeze: Float in [0, 0.8] {
            let harness = try EngineHarness(width: 300, height: 120)
            thick(harness, squeeze: squeeze)
            harness.draw(StrokeFixtures.line(from: CGPoint(x: 30, y: 60), to: CGPoint(x: 200, y: 60), pressure: 1...1))
            let heights = harness.heights(of: harness.drawingLayer)
            // Past the last dab's edge (x = 218), in the band the push reaches
            beyond.append(heights.at(x: 222, y: 60).x)
            XCTAssertGreaterThan(heights.at(x: 120, y: 60).x, 0.05, "the stroke is thick along its length")
        }
        XCTAssertLessThan(beyond[0], 0.002, "nothing beyond the end without pushing")
        XCTAssertGreaterThan(beyond[1], 0.05, "pushed paint beyond the end: \(beyond)")
    }

    func testPushingMovesPaintWithoutMakingOrLosingIt() throws {
        var totals: [Float] = []
        for squeeze: Float in [0, 0.8] {
            let harness = try EngineHarness(width: 300, height: 200)
            thick(harness, squeeze: squeeze)
            harness.draw(StrokeFixtures.line(from: CGPoint(x: 60, y: 100), to: CGPoint(x: 240, y: 100), pressure: 1...1))
            totals.append(total(harness.heights(of: harness.drawingLayer)))
        }
        XCTAssertEqual(totals[1], totals[0], accuracy: totals[0] * 0.15, "the same paint, moved: \(totals)")
    }

    func testBristlesCutGroovesAlongTheStroke() throws {
        var roughness: [Float] = []
        for grooves: Float in [0, 1] {
            let harness = try EngineHarness(width: 240, height: 120)
            thick(harness, squeeze: 0, grooves: grooves)
            harness.draw(StrokeFixtures.line(from: CGPoint(x: 20, y: 60), to: CGPoint(x: 220, y: 60), pressure: 1...1))
            let heights = harness.heights(of: harness.drawingLayer)
            // Across the stroke, well inside its edges: how much the height jumps from one row
            // to the next, against its mean
            let across = (48...72).map { heights.at(x: 120, y: $0).x }
            let jumps = zip(across, across.dropFirst()).map { abs($0 - $1) }
            roughness.append(jumps.reduce(0, +) / Float(jumps.count) / (across.reduce(0, +) / Float(across.count)))
        }
        XCTAssertLessThan(roughness[0], 0.05, "smooth without grooves: \(roughness)")
        XCTAssertGreaterThan(roughness[1], max(0.08, roughness[0] * 3), "ridged with them: \(roughness)")
    }

    /// The foot of a ridge is darker than open paper: paint higher beside it takes the sky.
    func testTheFootOfARidgeIsShaded() throws {
        let harness = try EngineHarness(width: 240, height: 120)
        thick(harness, squeeze: 0)
        harness.draw(StrokeFixtures.line(from: CGPoint(x: 20, y: 60), to: CGPoint(x: 220, y: 60), pressure: 1...1))
        func brightness(_ p: SIMD4<Float>) -> Float { (p.x + p.y + p.z) / 3 }
        let lit = harness.shown(relief: 1), flat = harness.shown(relief: 0)
        // Just outside the stroke's lower edge (radius 20 from y = 60), and well away from it
        let footLit = brightness(lit.at(x: 120, y: 81)), footFlat = brightness(flat.at(x: 120, y: 81))
        XCTAssertEqual(brightness(lit.at(x: 120, y: 105)), brightness(flat.at(x: 120, y: 105)), accuracy: 0.005, "open paper is as it was")
        XCTAssertLessThan(footLit, footFlat * 0.97, "the foot is shaded: \(footLit) against \(footFlat)")
    }

    /// A glossy finish puts a tight bright glint on the slopes that face the light; a matte
    /// one spreads a faint sheen over everything.
    func testGlossyPaintGlintsHarderThanMatteAndMatteHasTheBroaderSheen() throws {
        let harness = try EngineHarness(width: 240, height: 120)
        thick(harness, squeeze: 0, size: 80)
        // Dark paint, so a glint cannot run off the top of the range; a short bar, so its
        // rounded ends have slopes facing every way
        harness.viewModel.currentColor = StrokeColor(red: 0.1, green: 0.15, blue: 0.45, alpha: 1)
        harness.draw(StrokeFixtures.line(from: CGPoint(x: 90, y: 60), to: CGPoint(x: 150, y: 60), pressure: 1...1))
        func distance(_ x: Int, _ y: Int) -> Float { hypot(Float(min(max(x, 90), 150) - x), Float(60 - y)) }
        // The paint alone: where the unlit view is dark, so no paper gets in at the edge
        let flat = harness.shown(relief: 0)
        func isPaint(_ x: Int, _ y: Int) -> Bool { let p = flat.at(x: x, y: y); return (p.x + p.y + p.z) / 3 < 0.4 }
        func brightness(gloss: Float) -> (peak: Float, interior: Float) {
            let shown = harness.shown(relief: 1, gloss: gloss)
            var peak: Float = 0, sum: Float = 0, count: Float = 0
            for y in 10..<110 { for x in 40..<200 where isPaint(x, y) {
                let p = shown.at(x: x, y: y), b = (p.x + p.y + p.z) / 3
                peak = max(peak, b)
                if distance(x, y) <= 25 { sum += b; count += 1 }
            } }
            return (peak, sum / count)
        }
        let matte = brightness(gloss: 0), glossy = brightness(gloss: 1)
        XCTAssertGreaterThan(glossy.peak, matte.peak + 0.03, "the glint: \(glossy) against \(matte)")
        XCTAssertLessThan(glossy.peak, 0.99, "and not blown out")
        XCTAssertGreaterThan(matte.interior, glossy.interior + 0.015, "the sheen: \(matte) against \(glossy)")
    }

    func testTheKnifePushesPaintAboutWithoutAddingAny() throws {
        let harness = try EngineHarness(width: 240, height: 240)
        thick(harness, squeeze: 0)
        harness.draw(StrokeFixtures.line(from: CGPoint(x: 20, y: 120), to: CGPoint(x: 220, y: 120), pressure: 1...1))
        let before = harness.heights(of: harness.drawingLayer)
        let paintBefore = total(harness.pixels(of: harness.drawingLayer.texture))
        let base = before.at(x: 120, y: 120).x

        harness.select(.paletteKnife)
        harness.viewModel.brushSize = 40
        harness.draw(StrokeFixtures.line(from: CGPoint(x: 120, y: 20), to: CGPoint(x: 120, y: 220), pressure: 1...1))
        let after = harness.heights(of: harness.drawingLayer)
        XCTAssertLessThan(after.at(x: 120, y: 120).x, base * 0.5, "scraped down where the knife went")
        XCTAssertGreaterThan(after.at(x: 142, y: 120).x, base * 1.15, "and piled up beside it: \(after.at(x: 142, y: 120).x) against \(base)")
        XCTAssertLessThanOrEqual(total(harness.pixels(of: harness.drawingLayer.texture)), paintBefore * 1.02, "no paint added")
    }
}

