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
        // Mostly the same clumps two dabs on: they wander, slowly
        let here = across(bristled, x: 100), there = across(bristled, x: 180)
        var same = 0
        for (a, b) in zip(here, there) where (a > 0.5) == (b > 0.5) { same += 1 }
        XCTAssertGreaterThan(same, 44, "mostly the same streaks two dabs on: \(same) of 61 rows agree")
    }

    /// The bundle's layout changes along a stroke, slowly, and no two strokes share one: the
    /// profile across the stroke moves on a little in a diameter, more over many, and another
    /// stroke's is its own.
    func testTheBundleChangesAlongAStrokeAndBetweenStrokes() throws {
        // Dabs a diameter apart, so each stands alone with its centre at x = 20, 60, 100...
        func stroke(from x: CGFloat) throws -> PixelGrid {
            let harness = try EngineHarness(width: 760, height: 120)
            harness.select(brush(bristles: .init(count: 10, fan: 0, parting: 0, dryBrush: 0), spacing: 1))
            harness.viewModel.brushSize = 40
            harness.viewModel.currentColor = ink
            harness.draw(StrokeFixtures.line(from: CGPoint(x: x, y: 60), to: CGPoint(x: 740, y: 60), pressure: 1...1))
            return harness.pixels(of: harness.drawingLayer.texture)
        }
        func across(_ layer: PixelGrid, x: Int) -> [Float] {
            // Smoothed over three rows, so a streak a pixel over is a small difference, not a large one
            let p = (41...79).map { layer.at(x: x, y: $0).w }
            return (1..<(p.count - 1)).map { (p[$0 - 1] + p[$0] + p[$0 + 1]) / 3 }
        }
        func difference(_ a: [Float], _ b: [Float]) -> Float { zip(a, b).map { abs($0 - $1) }.reduce(0, +) / Float(a.count) }
        let one = try stroke(from: 20), other = try stroke(from: 24)
        let here = across(one, x: 100)
        let near = difference(here, across(one, x: 140))
        let far = [300, 420, 540, 660].map { difference(here, across(one, x: $0)) }.max()!
        let elsewhere = difference(here, across(other, x: 100))
        XCTAssertGreaterThan(near, 0.02, "a diameter on it has changed a little: \(near)")
        XCTAssertGreaterThan(far, near * 1.5, "many diameters on, more: \(far) against \(near)")
        XCTAssertGreaterThan(elsewhere, 0.05, "and another stroke is its own from the start: \(elsewhere)")
    }

    /// Two stray hairs sit at the bundle's full width whatever the touch, so when a light
    /// touch narrows the bundle they stand apart from it, for stretches of the stroke.
    func testStrayHairsStandApartFromANarrowedBundleNowAndThen() throws {
        let harness = try EngineHarness(width: 760, height: 120)
        harness.select(brush(bristles: .init(count: 10, fan: 0.8, parting: 0, dryBrush: 0), spacing: 0.1))
        harness.viewModel.brushSize = 40
        harness.viewModel.currentColor = ink
        harness.draw(StrokeFixtures.line(from: CGPoint(x: 20, y: 60), to: CGPoint(x: 740, y: 60), pressure: 0.3...0.3))
        let layer = harness.pixels(of: harness.drawingLayer.texture)
        // The bundle at this touch spans about 60% of the dab; the outer band is beyond it
        var withHair = 0, columns = 0, bundleReached = 0
        for x in stride(from: 60, to: 700, by: 4) {
            columns += 1
            let outer = (78...80).map { layer.at(x: x, y: $0).w }.max()! + (40...42).map { layer.at(x: x, y: $0).w }.max()!
            if outer > 0.1 { withHair += 1 }
            if (70...74).map({ layer.at(x: x, y: $0).w }).max()! > 0.5 { bundleReached += 1 }
        }
        XCTAssertLessThan(bundleReached, columns / 3, "the bundle itself stays narrow: \(bundleReached) of \(columns)")
        XCTAssertGreaterThan(withHair, columns / 10, "hairs out at the edge now and then: \(withHair) of \(columns)")
        XCTAssertLessThan(withHair, columns * 9 / 10, "and gone for stretches")
    }

    /// Pressed hard the bundle splays, and it holds the splay for about a diameter after
    /// the touch eases rather than snapping narrow at once.
    func testTheBundleHoldsItsSplayAfterTheTouchEases() throws {
        let harness = try EngineHarness(width: 400, height: 120)
        harness.select(brush(bristles: .init(count: 10, fan: 0.8, parting: 0, dryBrush: 0), spacing: 0.1))
        harness.viewModel.brushSize = 40
        harness.viewModel.currentColor = ink
        let points = (0...180).map { i -> StrokePoint in
            let x = CGFloat(20 + i * 2)
            return StrokePoint(position: CGPoint(x: x, y: 60), pressure: x < 180 ? 1 : 0.3, tiltX: 0, tiltY: 0, rotation: 0, timestamp: Double(i) * 0.005)
        }
        harness.draw(points)
        let layer = harness.pixels(of: harness.drawingLayer.texture)
        func width(at x: Int) -> Int {
            let profile = (30...90).map { layer.at(x: x, y: $0).w }
            var best = 0, run = 0
            for v in profile { run = v > 0.1 ? run + 1 : 0; best = max(best, run) }
            return best
        }
        // A fifth of a diameter after the touch eased the fan has barely come in; three on, it has
        let pressed = width(at: 120), justAfter = width(at: 188), later = width(at: 300)
        XCTAssertGreaterThan(justAfter, Int(Float(pressed) * 0.75), "still splayed just after the touch eased: \(justAfter) against \(pressed)")
        XCTAssertLessThan(later, Int(Float(pressed) * 0.7), "narrowed three diameters on: \(later)")
    }

    /// The bristle grain is streaks made in the shader: a height spread over 0...1 about as
    /// evenly as the old image's was, laid out afresh for every stroke.
    func testTheBristleStreaksAreSpreadEvenlyAndDifferByStroke() throws {
        func dab(at x: CGFloat) throws -> [Float] {
            var brush = BrushDescriptor.hardRound
            var settings = StampSettings(spacing: 1, flow: 1)
            settings.grain = .init(mode: .multiply, texture: .bristles, attachment: .stroke, scale: 1.0, depth: 1.0)
            brush.rendering = .stamp(settings); brush.mixing = .light; brush.opacity = 1; brush.hardness = 1
            brush.pressureDynamics = PressureDynamics(sizeRange: 1.0...1.0, opacityRange: 1.0...1.0)
            let harness = try EngineHarness(width: 300, height: 300)
            harness.select(brush); harness.viewModel.brushSize = 200
            harness.viewModel.currentColor = ink
            // One dab: a stroke shorter than the spacing
            harness.draw(StrokeFixtures.line(from: CGPoint(x: x, y: 150), to: CGPoint(x: x + 1, y: 150), pressure: 1...1))
            let layer = harness.pixels(of: harness.drawingLayer.texture)
            var values: [Float] = []
            for y in 90...210 { for dx in -60...60 { values.append(layer.at(x: Int(x) + dx, y: y).w) } }
            return values
        }
        let a = try dab(at: 150), b = try dab(at: 151)
        let mean = a.reduce(0, +) / Float(a.count)
        let spread = (a.map { ($0 - mean) * ($0 - mean) }.reduce(0, +) / Float(a.count)).squareRoot()
        let differing = zip(a, b).filter { abs($0 - $1) > 0.1 }.count
        XCTAssertEqual(mean, 0.5, accuracy: 0.08, "half covered on average: \(mean)")
        XCTAssertGreaterThan(spread, 0.2, "with real contrast: \(spread)")
        XCTAssertLessThan(spread, 0.32, "but not clipped to black and white")
        XCTAssertGreaterThan(differing, a.count / 3, "another stroke has other streaks: \(differing) of \(a.count) differ")
    }

    func testTheBundleNarrowsAtALightTouch() throws {
        func width(fan: Float, pressure: Float) throws -> Int {
            let harness = try canvas(brush(bristles: .init(count: 10, fan: fan, parting: 0, dryBrush: 0)))
            harness.draw(StrokeFixtures.line(from: CGPoint(x: 20, y: 60), to: CGPoint(x: 220, y: 60), pressure: pressure...pressure))
            // The bundle's own band: the longest run of covered rows, which a stray hair
            // out at the edge is not part of
            let profile = across(harness)
            var best = 0, run = 0
            for v in profile { run = v > 0.1 ? run + 1 : 0; best = max(best, run) }
            return best
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
