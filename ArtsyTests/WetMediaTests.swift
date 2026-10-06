import XCTest
@testable import Artsy

/// Strokes that dry as a wash: glazing, wet edges and granulation.
final class WetMediaTests: XCTestCase {
    private let blue = StrokeColor(red: 0.05, green: 0.1, blue: 0.8, alpha: 1)

    /// The Watercolor brush with its wet settings replaced.
    private func watercolor(edges: Float, granulation: Float, mixing: PaintMixing = .glaze) -> BrushDescriptor {
        var brush = BrushDescriptor.watercolor
        brush.wet = BrushDescriptor.Wet(edges: edges, granulation: granulation, grainScale: 1)
        brush.mixing = mixing
        return brush
    }

    private func worst(_ a: PixelGrid, _ b: PixelGrid) -> Float {
        var worst: Float = 0
        for i in a.values.indices { worst = max(worst, abs(a.values[i] - b.values[i])) }
        return worst
    }

    // MARK: - Glaze

    /// A glaze darkens what is under it and never covers it: blue over yellow is a dark
    /// olive, not the purple-grey an average would give. Over nothing it is simply blue.
    func testAGlazeDarkensInsteadOfCovering() throws {
        func centre(mixing: PaintMixing, overYellow: Bool) throws -> SIMD4<Float> {
            let harness = try EngineHarness(width: 200, height: 100)
            if overYellow { harness.fill(harness.drawingLayer, red: 0.95, green: 0.8, blue: 0.05) }
            harness.select(watercolor(edges: 0, granulation: 0, mixing: mixing))
            harness.viewModel.brushSize = 40
            harness.viewModel.currentColor = blue
            harness.draw(StrokeFixtures.line(from: CGPoint(x: 20, y: 50), to: CGPoint(x: 180, y: 50), pressure: 1...1))
            return harness.pixels(of: harness.drawingLayer.texture).at(x: 100, y: 50)
        }
        let glazed = try centre(mixing: .glaze, overYellow: true)
        XCTAssertLessThan(glazed.z, 0.1, "the glaze lets through no blue the yellow had not got: \(glazed)")
        XCTAssertLessThan(glazed.x, 0.8, "and darkens the yellow")
        XCTAssertGreaterThan(glazed.x, 0.2)
        XCTAssertEqual(glazed.w, 1, accuracy: 0.01)

        let averaged = try centre(mixing: .light, overYellow: true)
        XCTAssertGreaterThan(averaged.z, 0.25, "averaging the two adds blue: \(averaged)")

        let alone = try centre(mixing: .glaze, overYellow: false)
        XCTAssertGreaterThan(alone.w, 0.4, "over nothing, the wash itself: \(alone)")
        XCTAssertEqual(alone.z / alone.w, 0.8, accuracy: 0.02, "in its own colour")
    }

    // MARK: - Wet edges

    /// Across a wash stroke, the darkest band is just inside the edge, not the middle, and
    /// the edge itself is crisp rather than a long soft falloff.
    func testPigmentGathersAtTheEdge() throws {
        func profile(edges: Float) throws -> [Float] {
            let harness = try EngineHarness(width: 240, height: 140)
            harness.select(watercolor(edges: edges, granulation: 0))
            harness.viewModel.brushSize = 60
            harness.viewModel.currentColor = blue
            harness.draw(StrokeFixtures.line(from: CGPoint(x: 20, y: 70), to: CGPoint(x: 220, y: 70), pressure: 1...1))
            let layer = harness.pixels(of: harness.drawingLayer.texture)
            // Outward from the middle of the stroke
            return (0...45).map { layer.at(x: 120, y: 70 + $0).w }
        }
        let wet = try profile(edges: 0.8), dry = try profile(edges: 0)

        let middle = wet[0], peak = wet.max()!, peakAt = wet.firstIndex(of: peak)!
        XCTAssertGreaterThan(middle, 0.3)
        XCTAssertGreaterThan(peak, middle * 1.15, "a darker rim: \(wet.map { String(format: "%.2f", $0) })")
        XCTAssertTrue((6...30).contains(peakAt), "the rim is near the edge, at \(peakAt) px out")
        XCTAssertLessThan(wet.last!, 0.01, "nothing beyond the stroke")

        let dryPeakAt = dry.firstIndex(of: dry.max()!)!
        XCTAssertLessThan(dryPeakAt, 6, "without wet edges the middle is darkest")
        for (a, b) in zip(dry, dry.dropFirst()) { XCTAssertLessThanOrEqual(b, a + 0.01, "and it only fades outward") }

        func softPixels(_ profile: [Float]) -> Int { profile.filter { $0 > 0.03 && $0 < middle * 0.5 }.count }
        XCTAssertLessThan(softPixels(wet), max(2, softPixels(dry) / 2), "a crisper boundary: \(softPixels(wet)) vs \(softPixels(dry)) soft px")
    }

    // MARK: - Granulation

    /// Pigment settles into the paper's valleys, which belong to the canvas: the same stroke
    /// in the same place settles the same way, and a shifted stroke meets the same paper.
    func testGranulationFollowsThePaper() throws {
        func alphas(granulation: Float, offset: CGFloat) throws -> PixelGrid {
            let harness = try EngineHarness(width: 240, height: 100)
            harness.select(watercolor(edges: 0, granulation: granulation))
            harness.viewModel.brushSize = 60
            harness.viewModel.currentColor = blue
            harness.draw(StrokeFixtures.line(from: CGPoint(x: 20 + offset, y: 50), to: CGPoint(x: 220 + offset, y: 50), pressure: 1...1))
            return harness.pixels(of: harness.drawingLayer.texture)
        }
        func patch(_ grid: PixelGrid) -> [Float] {
            (60..<180).flatMap { x in (40..<60).map { y in grid.at(x: x, y: y).w } }
        }
        func spread(_ values: [Float]) -> Float {
            let mean = values.reduce(0, +) / Float(values.count)
            return (values.map { ($0 - mean) * ($0 - mean) }.reduce(0, +) / Float(values.count)).squareRoot()
        }
        let grainy = patch(try alphas(granulation: 0.8, offset: 0))
        let smooth = patch(try alphas(granulation: 0, offset: 0))
        XCTAssertGreaterThan(spread(grainy), 0.04, "the wash varies with the paper")
        XCTAssertLessThan(spread(smooth), 0.02, "and is even without granulation")
        let grainyMean = grainy.reduce(0, +) / Float(grainy.count), smoothMean = smooth.reduce(0, +) / Float(smooth.count)
        XCTAssertEqual(grainyMean, smoothMean, accuracy: smoothMean * 0.1, "about as much pigment overall")

        XCTAssertEqual(patch(try alphas(granulation: 0.8, offset: 0)), grainy, "repeatable")
        let shifted = patch(try alphas(granulation: 0.8, offset: 9))
        let agreeing = zip(grainy, shifted).filter { ($0 > grainyMean) == ($1 > grainyMean) }.count
        XCTAssertGreaterThan(Double(agreeing) / Double(grainy.count), 0.8, "the same pixels of paper take the pigment")
    }

    // MARK: - Engine integration

    /// The composite while the pen is down shows the same wash the merge at pen-up makes.
    func testPreviewMatchesTheMerge() throws {
        let harness = try EngineHarness(width: 200, height: 100)
        harness.fill(harness.drawingLayer, red: 0.95, green: 0.8, blue: 0.05, alpha: 0.7)
        harness.select(.watercolor)
        harness.viewModel.brushSize = 40
        harness.viewModel.currentColor = blue
        let points = StrokeFixtures.wave(from: CGPoint(x: 20, y: 50), length: 160, amplitude: 15, cycles: 1)
        harness.renderer.beginStroke()
        harness.viewModel.beginStroke(point: points[0])
        points.dropFirst().forEach(harness.viewModel.continueStroke(point:))
        let preview = harness.composite()
        harness.renderer.finalizeStroke()
        harness.viewModel.endStroke()
        XCTAssertLessThan(worst(preview, harness.composite()), 0.01)
    }

    func testUndoRestoresAWashExactly() throws {
        let harness = try EngineHarness(width: 160, height: 80)
        harness.fill(harness.drawingLayer, red: 0.95, green: 0.8, blue: 0.05)
        let before = harness.pixels(of: harness.drawingLayer.texture)
        harness.select(.watercolor)
        harness.viewModel.currentColor = blue
        harness.draw(StrokeFixtures.line(from: CGPoint(x: 10, y: 40), to: CGPoint(x: 150, y: 40)))
        XCTAssertGreaterThan(worst(before, harness.pixels(of: harness.drawingLayer.texture)), 0.1)
        harness.viewModel.performUndo(renderer: harness.renderer)
        XCTAssertEqual(worst(before, harness.pixels(of: harness.drawingLayer.texture)), 0)
    }

    // MARK: - Brush files

    func testWetSettingsSurviveTheBrushFileAndTheRetiredRibbonShaderStillReads() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ArtsyWet-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let library = BrushLibrary(directory: directory)

        let file = directory.appendingPathComponent("watercolor.artsybrush")
        try library.export(.watercolor, to: file)
        let json = try String(contentsOf: file, encoding: .utf8)
        XCTAssertTrue(json.contains("\"mixing\" : \"glaze\""))
        XCTAssertTrue(json.contains("\"granulation\""))
        let imported = try library.importBrush(from: file)
        XCTAssertEqual(imported.wet, BrushDescriptor.watercolor.wet)
        XCTAssertEqual(imported.mixing, .glaze)
        XCTAssertEqual(imported.rendering, BrushDescriptor.watercolor.rendering)

        // A ribbon brush saved with the old watercolor shader opens as a plain ribbon
        let ribbon = directory.appendingPathComponent("ribbon.artsybrush")
        try library.export(.hardRound, to: ribbon)
        let old = try String(contentsOf: ribbon, encoding: .utf8).replacingOccurrences(of: "\"procedural\"", with: "\"watercolor\"")
        XCTAssertTrue(old.contains("\"watercolor\""))
        let oldFile = directory.appendingPathComponent("old ribbon.artsybrush")
        try old.write(to: oldFile, atomically: true, encoding: .utf8)
        XCTAssertEqual(try library.importBrush(from: oldFile).rendering, .ribbon(.procedural))
    }
}
