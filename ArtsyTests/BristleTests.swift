import XCTest
@testable import Artsy

private extension BrushDescriptor {
    var stampSettings: StampSettings? {
        if case .stamp(let settings) = rendering { return settings }
        return nil
    }
}

/// The tip as a bundle of bristles: streaks across the stroke, a bundle that narrows at a
/// light touch and parts at speed, and a light touch that skips the paper's valleys.
final class BristleTests: XCTestCase {
    private let ink = StrokeColor(red: 0.1, green: 0.1, blue: 0.1, alpha: 1)

    /// A round opaque brush with or without a bundle of bristles, following the stroke.
    private func brush(bristles: StampSettings.Bristles?, size: Float = 40, spacing: Float = 0.1) -> BrushDescriptor {
        var brush = BrushDescriptor.hardRound
        brush.name = bristles == nil ? "Plain" : "Bristled"
        var settings = StampSettings(spacing: spacing, flow: 1)
        settings.bristles = bristles
        settings.followsDirection = true
        brush.rendering = .stamp(settings)
        brush.mixing = .light
        brush.opacity = 1
        brush.pressureDynamics = PressureDynamics(sizeRange: 1.0...1.0, opacityRange: 1.0...1.0)
        return brush
    }

    private func canvas(_ brush: BrushDescriptor, size: Float = 40) throws -> EngineHarness {
        let harness = try EngineHarness(width: 240, height: 120)
        harness.select(brush)
        harness.viewModel.brushSize = size
        harness.viewModel.currentColor = ink
        return harness
    }

    /// Alpha across the stroke at x = 120, from y = 30 to 90.
    private func across(_ harness: EngineHarness) -> [Float] {
        let layer = harness.pixels(of: harness.drawingLayer.texture)
        return (30...90).map { layer.at(x: 120, y: $0).w }
    }

    private func turns(_ profile: [Float]) -> Int {
        // Direction changes of more than a little, ignoring noise
        var count = 0, rising: Bool? = nil
        for (a, b) in zip(profile, profile.dropFirst()) where abs(b - a) > 0.08 {
            let up = b > a
            if let was = rising, was != up { count += 1 }
            rising = up
        }
        return count
    }

    /// One dab is a bundle of streaks across. Dabs overlap many times over along a stroke,
    /// so the tone between clumps fills in; the streaks of a stroke come from the carry
    /// and the grain, and the bundle's own gaps appear at speed and at a light touch.
    func testTheTipIsABundleOfStreaks() throws {
        // Dabs a diameter apart, so each dab stands alone with its centre at x = 20, 60, 100...
        let bristled = try canvas(brush(bristles: .init(count: 10, fan: 0, parting: 0, dryBrush: 0), spacing: 1))
        bristled.draw(StrokeFixtures.line(from: CGPoint(x: 20, y: 60), to: CGPoint(x: 220, y: 60), pressure: 1...1))
        let plain = try canvas(brush(bristles: nil, spacing: 1))
        plain.draw(StrokeFixtures.line(from: CGPoint(x: 20, y: 60), to: CGPoint(x: 220, y: 60), pressure: 1...1))
        func across(_ harness: EngineHarness, x: Int) -> [Float] {
            let layer = harness.pixels(of: harness.drawingLayer.texture)
            return (30...90).map { layer.at(x: x, y: $0).w }
        }
        let streaky = across(bristled, x: 100), smooth = across(plain, x: 100)
        XCTAssertGreaterThan(streaky[30], 0.5, "covered in the middle")
        XCTAssertGreaterThanOrEqual(turns(streaky), 3, "streaks across the dab: \(streaky.map { String(format: "%.1f", $0) })")
        XCTAssertLessThanOrEqual(turns(smooth), 1, "a plain tip is even across: \(smooth.map { String(format: "%.1f", $0) })")
        // The same clumps at every dab
        let here = across(bristled, x: 100), there = across(bristled, x: 180)
        var same = 0
        for (a, b) in zip(here, there) where (a > 0.5) == (b > 0.5) { same += 1 }
        XCTAssertGreaterThan(same, 52, "the same streaks two dabs on: \(same) of 61 rows agree")
    }

    func testTheBundleNarrowsAtALightTouch() throws {
        func width(fan: Float, pressure: Float) throws -> Int {
            let harness = try canvas(brush(bristles: .init(count: 10, fan: fan, parting: 0, dryBrush: 0)))
            harness.draw(StrokeFixtures.line(from: CGPoint(x: 20, y: 60), to: CGPoint(x: 220, y: 60), pressure: pressure...pressure))
            let profile = across(harness)
            let covered = profile.indices.filter { profile[$0] > 0.1 }
            return covered.isEmpty ? 0 : covered.last! - covered.first! + 1
        }
        let full = try width(fan: 0.8, pressure: 1), light = try width(fan: 0.8, pressure: 0.3), stiff = try width(fan: 0, pressure: 0.3)
        XCTAssertLessThan(light, Int(Float(full) * 0.7), "a light touch narrows the bundle: \(light) px against \(full)")
        XCTAssertGreaterThan(stiff, Int(Float(full) * 0.85), "a bundle that does not fan stays wide: \(stiff) px")
    }

    func testTheClumpsPartAtSpeed() throws {
        func coverage(parting: Float, duration: Double) throws -> Float {
            let harness = try canvas(brush(bristles: .init(count: 10, fan: 0, parting: parting, dryBrush: 0)))
            harness.draw(StrokeFixtures.line(from: CGPoint(x: 20, y: 60), to: CGPoint(x: 220, y: 60), pressure: 1...1,
                                             duration: duration))
            let layer = harness.pixels(of: harness.drawingLayer.texture)
            var covered: Float = 0
            for y in 45...75 { for x in 60...180 where layer.at(x: x, y: y).w > 0.5 { covered += 1 } }
            return covered / Float(31 * 121)
        }
        // 200 px in 2 s is a slow stroke; in 0.08 s it is a fast one
        let slow = try coverage(parting: 0.8, duration: 2), fast = try coverage(parting: 0.8, duration: 0.08)
        XCTAssertLessThan(fast, slow * 0.8, "a fast stroke breaks into streaks: \(fast) against \(slow)")
        let stiffSlow = try coverage(parting: 0, duration: 2), stiffFast = try coverage(parting: 0, duration: 0.08)
        XCTAssertEqual(stiffFast, stiffSlow, accuracy: 0.03, "a bundle that does not part is the same at any speed")
    }

    func testALightTouchSkipsTheValleysOfThePaper() throws {
        func peaksAgainstValleys(dryBrush: Float, pressure: Float) throws -> Float {
            let harness = try canvas(brush(bristles: .init(count: 10, fan: 0, parting: 0, dryBrush: dryBrush)), size: 50)
            harness.draw(StrokeFixtures.line(from: CGPoint(x: 20, y: 60), to: CGPoint(x: 220, y: 60), pressure: pressure...pressure))
            let layer = harness.pixels(of: harness.drawingLayer.texture)
            let paper = BrushTextureLibrary.paperGrainPixels(), size = BrushTextureLibrary.grainSize
            var peaks: [Float] = [], valleys: [Float] = []
            for y in 50...70 { for x in 40...200 {
                let h = Float(paper[(y % size) * size + x % size]) / 255
                let a = layer.at(x: x, y: y).w
                if h > 0.75 { peaks.append(a) } else if h < 0.25 { valleys.append(a) }
            } }
            return peaks.reduce(0, +) / Float(peaks.count) / max(0.001, valleys.reduce(0, +) / Float(valleys.count))
        }
        let dry = try peaksAgainstValleys(dryBrush: 1, pressure: 0.35)
        XCTAssertGreaterThan(dry, 1.5, "a light touch leaves the valleys: peaks \(dry)× the valleys")
        XCTAssertLessThan(try peaksAgainstValleys(dryBrush: 1, pressure: 1), 1.15, "pressed hard it fills them")
        XCTAssertLessThan(try peaksAgainstValleys(dryBrush: 0, pressure: 0.35), 1.15, "and without dry-brushing it fills them at any touch")
    }

    func testBristleSettingsSurviveTheBrushFileAndOldFilesHaveNone() throws {
        let brush = brush(bristles: .init(count: 7, fan: 0.3, parting: 0.9, dryBrush: 0.1))
        let back = try JSONDecoder().decode(BrushDescriptor.self, from: JSONEncoder().encode(brush))
        XCTAssertEqual(back.stampSettings?.bristles, brush.stampSettings?.bristles)
        var json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(brush)) as! [String: Any]
        var rendering = json["rendering"] as! [String: Any]
        func stripped(_ value: Any) -> Any {
            if var dict = value as? [String: Any] { dict["bristles"] = nil; return dict.mapValues(stripped) }
            if let array = value as? [Any] { return array.map(stripped) }
            return value
        }
        rendering = stripped(rendering) as! [String: Any]
        json["rendering"] = rendering
        let old = try JSONDecoder().decode(BrushDescriptor.self, from: JSONSerialization.data(withJSONObject: json))
        XCTAssertNil(old.stampSettings?.bristles)
    }
}
