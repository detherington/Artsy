import XCTest
@testable import Artsy

/// Pigment mixing: brushes whose colour mixes with the paint under it as paint would.
final class PigmentMixingTests: XCTestCase {
    private var context: MetalContext { EngineHarness.sharedContext }

    // The canvas holds Display P3 components, gamma-encoded; references are in sRGB.
    private static func decode(_ c: Float) -> Float { c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4) }
    private static func encode(_ v: Float) -> Float {
        let v = max(0, min(1, v))
        return v <= 0.0031308 ? v * 12.92 : 1.055 * pow(v, 1 / 2.4) - 0.055
    }

    private func p3(hex: UInt32) -> SIMD3<Float> {
        let s = SIMD3(Self.decode(Float(hex >> 16 & 0xFF) / 255), Self.decode(Float(hex >> 8 & 0xFF) / 255),
                      Self.decode(Float(hex & 0xFF) / 255))
        let linear = SIMD3(0.8224621 * s.x + 0.1775380 * s.y,
                           0.0331941 * s.x + 0.9668058 * s.y,
                           0.0170827 * s.x + 0.0723974 * s.y + 0.9105199 * s.z)
        return SIMD3(Self.encode(linear.x), Self.encode(linear.y), Self.encode(linear.z))
    }

    private func sRGB8(p3 c: SIMD3<Float>) -> [Int] {
        let l = SIMD3(Self.decode(c.x), Self.decode(c.y), Self.decode(c.z))
        let s = SIMD3(1.2249401762805587 * l.x - 0.22494017628055865 * l.y,
                      -0.04205695470968819 * l.x + 1.0420569547096881 * l.y,
                      -0.019637554590334483 * l.x - 0.07863604555063188 * l.y + 1.0982736001409685 * l.z)
        return [s.x, s.y, s.z].map { Int((Self.encode($0) * 255).rounded()) }
    }

    // MARK: - The model

    /// spectral.js's own example: its blue and yellow mixed half and half make this green.
    func testMatchesTheSpectralJSReference() {
        let mixed = context.mixPigments([(p3(hex: 0x002185), p3(hex: 0xFCD200), 0.5)])[0]
        let expected = [0x3D, 0x93, 0x3E]
        for (got, want) in zip(sRGB8(p3: mixed), expected) {
            XCTAssertEqual(got, want, accuracy: 3, "\(sRGB8(p3: mixed)) vs #3D933E")
        }
    }

    func testEndsComeBackExactlyAndAColourMixedWithItselfIsUnchanged() {
        let a = p3(hex: 0x8040C0), b = p3(hex: 0x20A060), black = SIMD3<Float>(0, 0, 0)
        let results = context.mixPigments([(a, b, 0), (a, b, 1), (a, a, 0.5), (black, a, 0), (a, black, 0.3)])
        for i in 0..<3 {
            XCTAssertEqual(results[0][i], a[i], accuracy: 1e-4, "t = 0 gives the first colour")
            XCTAssertEqual(results[1][i], b[i], accuracy: 1e-4, "t = 1 gives the second")
            XCTAssertEqual(results[2][i], a[i], accuracy: 1e-4, "a colour with itself")
            XCTAssertEqual(results[3][i], 0, accuracy: 1e-4, "black stays black")
        }
        let darkened = results[4]
        XCTAssertLessThan(darkened.x + darkened.y + darkened.z, (a.x + a.y + a.z) * 0.9, "black darkens a colour")
        XCTAssertGreaterThan(darkened.x + darkened.y + darkened.z, (a.x + a.y + a.z) * 0.3, "but a third of it does not blacken it")
    }

    func testBlueAndYellowMakeGreenNotGrey() {
        let blue = SIMD3<Float>(0.05, 0.1, 0.8), yellow = SIMD3<Float>(0.95, 0.8, 0.05)
        let green = context.mixPigments([(blue, yellow, 0.5)])[0]
        XCTAssertGreaterThan(green.y, green.x * 1.5)
        XCTAssertGreaterThan(green.y, green.z * 1.5)
    }

    // MARK: - Brushes

    private let blue = StrokeColor(red: 0.05, green: 0.1, blue: 0.8, alpha: 1)
    private let yellow = StrokeColor(red: 0.95, green: 0.8, blue: 0.05, alpha: 1)

    /// Half-opacity yellow over a blue layer: green with mixing, grey without.
    func testAMixingBrushMakesGreenOverBlue() throws {
        func overlap(mixing: Bool) throws -> SIMD4<Float> {
            let harness = try EngineHarness(width: 200, height: 100)
            harness.fill(harness.drawingLayer, red: 0.05, green: 0.1, blue: 0.8)
            var brush = BrushDescriptor.oil
            brush.mixing = mixing ? .pigment : .light
            harness.select(brush)
            harness.viewModel.brushSize = 40
            harness.viewModel.brushOpacity = 0.5
            harness.viewModel.currentColor = yellow
            harness.draw(StrokeFixtures.line(from: CGPoint(x: 20, y: 50), to: CGPoint(x: 180, y: 50), pressure: 1...1))
            return harness.pixels(of: harness.drawingLayer.texture).at(x: 100, y: 50)
        }
        let mixed = try overlap(mixing: true), plain = try overlap(mixing: false)
        XCTAssertEqual(mixed.w, 1, accuracy: 0.01, "coverage is unchanged by mixing")
        XCTAssertGreaterThan(mixed.y, mixed.x * 1.3, "green: \(mixed)")
        XCTAssertGreaterThan(mixed.y, mixed.z * 1.3)
        XCTAssertEqual(plain.x, 0.5, accuracy: 0.03, "without mixing it is the average of the two: \(plain)")
        XCTAssertEqual(plain.y, 0.45, accuracy: 0.03)
        XCTAssertEqual(plain.z, 0.425, accuracy: 0.03)
    }

    /// Painting over nothing, or over the same colour, mixing changes nothing.
    func testMixingLeavesPlainStrokesAlone() throws {
        func layer(mixing: Bool, over fill: StrokeColor?) throws -> PixelGrid {
            let harness = try EngineHarness(width: 160, height: 80)
            if let fill { harness.fill(harness.drawingLayer, red: Double(fill.red), green: Double(fill.green), blue: Double(fill.blue)) }
            var brush = BrushDescriptor.acrylic
            brush.mixing = mixing ? .pigment : .light
            harness.select(brush)
            harness.viewModel.currentColor = yellow
            harness.draw(StrokeFixtures.wave(from: CGPoint(x: 10, y: 40), length: 140, amplitude: 15, cycles: 1.5))
            return harness.pixels(of: harness.drawingLayer.texture)
        }
        func worst(_ a: PixelGrid, _ b: PixelGrid) -> Float {
            var worst: Float = 0
            for i in a.values.indices { worst = max(worst, abs(a.values[i] - b.values[i])) }
            return worst
        }
        XCTAssertLessThan(worst(try layer(mixing: true, over: nil), try layer(mixing: false, over: nil)), 0.003)
        XCTAssertLessThan(worst(try layer(mixing: true, over: yellow), try layer(mixing: false, over: yellow)), 0.003)
    }

    /// The composite while the pen is down shows the same mix the merge at pen-up makes.
    func testPreviewMatchesTheMerge() throws {
        let harness = try EngineHarness(width: 200, height: 100)
        harness.fill(harness.drawingLayer, red: 0.05, green: 0.1, blue: 0.8, alpha: 0.7)
        harness.select(.oil)
        harness.viewModel.brushSize = 40
        harness.viewModel.brushOpacity = 0.6
        harness.viewModel.currentColor = yellow
        let points = StrokeFixtures.wave(from: CGPoint(x: 20, y: 50), length: 160, amplitude: 15, cycles: 1)
        harness.renderer.beginStroke()
        harness.viewModel.beginStroke(point: points[0])
        points.dropFirst().forEach(harness.viewModel.continueStroke(point:))
        let preview = harness.composite()
        harness.renderer.finalizeStroke()
        harness.viewModel.endStroke()
        let merged = harness.composite()
        var worst: Float = 0
        for i in preview.values.indices { worst = max(worst, abs(preview.values[i] - merged.values[i])) }
        XCTAssertLessThan(worst, 0.01)
        XCTAssertGreaterThan(merged.at(x: 100, y: 50).y, merged.at(x: 100, y: 50).z * 1.3, "and it is a mix: \(merged.at(x: 100, y: 50))")
    }

    /// Blue dragged into yellow: where the smear's soft front meets the yellow, a mixing
    /// smudge leaves green; a plain one leaves the greys between the two.
    func testASmudgeMixesWhatItDrags() throws {
        func greenest(mixing: Bool) throws -> Float {
            let harness = try EngineHarness(width: 240, height: 100)
            harness.select(.hardRound)
            harness.viewModel.brushSize = 100
            harness.viewModel.currentColor = yellow
            harness.draw(StrokeFixtures.line(from: CGPoint(x: 100, y: 50), to: CGPoint(x: 240, y: 50), pressure: 1...1))
            harness.viewModel.currentColor = blue
            harness.draw(StrokeFixtures.line(from: CGPoint(x: 0, y: 50), to: CGPoint(x: 60, y: 50), pressure: 1...1))
            var brush = BrushDescriptor.smudge
            brush.mixing = mixing ? .pigment : .light
            harness.select(brush)
            harness.viewModel.brushSize = 36
            harness.draw(StrokeFixtures.line(from: CGPoint(x: 90, y: 50), to: CGPoint(x: 150, y: 50), pressure: 1...1))
            let layer = harness.pixels(of: harness.drawingLayer.texture)
            // How much green leads the other two channels, at best, across the front
            return (130...190).map { x in
                let p = layer.at(x: x, y: 50)
                return p.y - max(p.x, p.z)
            }.max()!
        }
        XCTAssertGreaterThan(try greenest(mixing: true), 0.1)
        XCTAssertLessThan(try greenest(mixing: false), 0.02, "no blend of this blue and yellow leads with green")
    }

    func testTheToggleSurvivesTheBrushFileAndOlderFilesReadAsOff() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ArtsyPigments-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let library = BrushLibrary(directory: directory)
        let file = directory.appendingPathComponent("oil.artsybrush")
        try library.export(.oil, to: file)
        let json = try String(contentsOf: file, encoding: .utf8)
        XCTAssertTrue(json.contains("\"mixing\" : \"pigment\""))
        XCTAssertEqual(try library.importBrush(from: file).mixing, .pigment)

        // Before `mixing` the setting was a boolean
        let legacy = json.replacingOccurrences(of: "\"mixing\" : \"pigment\"", with: "\"mixesPigments\" : true")
        let legacyFile = directory.appendingPathComponent("legacy.artsybrush")
        try legacy.write(to: legacyFile, atomically: true, encoding: .utf8)
        XCTAssertEqual(try library.importBrush(from: legacyFile).mixing, .pigment)

        // And before that there was nothing
        let older = json.replacingOccurrences(of: "\"mixing\" : \"pigment\",", with: "")
            .replacingOccurrences(of: ",\n    \"mixing\" : \"pigment\"", with: "")
        XCTAssertFalse(older.contains("mixing"), "the key is gone from the older file")
        let olderFile = directory.appendingPathComponent("older.artsybrush")
        try older.write(to: olderFile, atomically: true, encoding: .utf8)
        XCTAssertEqual(try library.importBrush(from: olderFile).mixing, .light)
    }
}
