import XCTest
@testable import Artsy

/// Smudge brushes: dabs that move the paint already on the layer.
final class SmudgeBrushTests: XCTestCase {
    private let red = StrokeColor(red: 1, green: 0, blue: 0, alpha: 1)
    private let blue = StrokeColor(red: 0, green: 0, blue: 1, alpha: 1)

    /// A canvas whose drawing layer has a solid red block on its left, ending at x ≈ 110,
    /// and nothing to its right.
    private func canvasWithRedBlock(width: Int = 260, height: Int = 120) throws -> EngineHarness {
        let harness = try EngineHarness(width: width, height: height)
        harness.select(.hardRound)
        harness.viewModel.brushSize = 100
        harness.viewModel.currentColor = red
        harness.draw(StrokeFixtures.line(from: CGPoint(x: 10, y: 60), to: CGPoint(x: 60, y: 60), pressure: 1...1))
        let layer = harness.pixels(of: harness.drawingLayer.texture)
        XCTAssertEqual(layer.at(x: 100, y: 60).w, 1, accuracy: 0.01, "solid red to the left of the edge")
        XCTAssertEqual(layer.at(x: 120, y: 60).w, 0, accuracy: 0.001, "nothing to its right")
        return harness
    }

    private func smudge(_ harness: EngineHarness, strength: Float? = nil, mode: StampSettings.Smudge.Mode? = nil,
                        colorRate: Float? = nil, size: Float = 36) -> BrushDescriptor {
        var brush = BrushDescriptor.smudge
        guard case .stamp(var settings) = brush.rendering, var smudge = settings.smudge else {
            fatalError("Smudge is not a smudge brush")
        }
        if let strength { smudge.strength = strength }
        if let mode { smudge.mode = mode }
        if let colorRate { smudge.colorRate = colorRate }
        settings.smudge = smudge
        brush.rendering = .stamp(settings)
        harness.select(brush)
        harness.viewModel.brushSize = size
        return brush
    }

    private func worstDifference(_ a: PixelGrid, _ b: PixelGrid) -> Float {
        var worst: Float = 0
        for i in a.values.indices { worst = max(worst, abs(a.values[i] - b.values[i])) }
        return worst
    }

    // MARK: - Smearing

    /// Dragging from paint into nothing carries the paint along, fading as it goes, and
    /// only where the brush went.
    func testSmearingDragsPaintOutOfItsEdge() throws {
        let harness = try canvasWithRedBlock()
        _ = smudge(harness, strength: 0.75)
        harness.draw(StrokeFixtures.line(from: CGPoint(x: 90, y: 60), to: CGPoint(x: 200, y: 60), pressure: 1...1))
        let layer = harness.pixels(of: harness.drawingLayer.texture)

        let near = layer.at(x: 130, y: 60), far = layer.at(x: 160, y: 60)
        XCTAssertGreaterThan(near.w, 0.3, "paint carried 20 px past the edge")
        XCTAssertGreaterThan(far.w, 0.05, "and 50 px past it")
        XCTAssertLessThan(far.w, near.w, "fading as it goes")
        XCTAssertEqual(near.x, near.w, accuracy: 0.01, "and it is the red that was there")
        XCTAssertEqual(near.y, 0, accuracy: 0.01)

        XCTAssertEqual(layer.at(x: 160, y: 20).w, 0, accuracy: 0.001, "nothing moved outside the brush's path")
        XCTAssertEqual(layer.at(x: 240, y: 60).w, 0, accuracy: 0.001, "nor beyond where it stopped")
        XCTAssertEqual(layer.at(x: 60, y: 60).w, 1, accuracy: 0.01, "the block itself is still solid")
    }

    /// Carry 1 moves the paint without loss; carry 0 moves nothing.
    func testCarryDecidesHowFarPaintTravels() throws {
        func alpha(at x: Int, strength: Float) throws -> Float {
            let harness = try canvasWithRedBlock()
            _ = smudge(harness, strength: strength)
            harness.draw(StrokeFixtures.line(from: CGPoint(x: 90, y: 60), to: CGPoint(x: 200, y: 60), pressure: 1...1))
            return harness.pixels(of: harness.drawingLayer.texture).at(x: x, y: 60).w
        }
        XCTAssertEqual(try alpha(at: 190, strength: 1), 1, accuracy: 0.02, "full carry: solid red all the way")
        XCTAssertEqual(try alpha(at: 130, strength: 0), 0, accuracy: 0.001, "no carry: nothing moves")
        let half = try alpha(at: 130, strength: 0.5), most = try alpha(at: 130, strength: 0.9)
        XCTAssertGreaterThan(most, half)
        XCTAssertGreaterThan(half, 0.02)
    }

    /// The brush's own colour can go in with the carried paint: at 100% it paints like any
    /// other brush, so it leaves a mark on an empty layer.
    func testColourRateAddsTheBrushColour() throws {
        func blueness(colorRate: Float) throws -> Float {
            let harness = try EngineHarness(width: 200, height: 100)
            _ = smudge(harness, colorRate: colorRate)
            harness.viewModel.currentColor = blue
            harness.draw(StrokeFixtures.line(from: CGPoint(x: 20, y: 50), to: CGPoint(x: 180, y: 50), pressure: 1...1))
            return harness.pixels(of: harness.drawingLayer.texture).at(x: 100, y: 50).z
        }
        XCTAssertEqual(try blueness(colorRate: 0), 0, accuracy: 0.001, "a pure smudge adds nothing to an empty layer")
        XCTAssertGreaterThan(try blueness(colorRate: 0.5), 0.3)
        XCTAssertEqual(try blueness(colorRate: 1), 1, accuracy: 0.02)
    }

    // MARK: - Dulling

    /// Dulling softens an edge in place: paint from both sides mixes across it, but none
    /// is carried off along the stroke.
    func testDullingBlursAnEdgeWithoutDragging() throws {
        let harness = try canvasWithRedBlock()
        _ = smudge(harness, strength: 0.75, mode: .dulling)
        harness.draw(StrokeFixtures.line(from: CGPoint(x: 90, y: 60), to: CGPoint(x: 200, y: 60), pressure: 1...1))
        let layer = harness.pixels(of: harness.drawingLayer.texture)

        XCTAssertLessThan(layer.at(x: 104, y: 60).w, 0.9, "just inside the edge has thinned")
        XCTAssertGreaterThan(layer.at(x: 116, y: 60).w, 0.1, "just outside it has gained")
        XCTAssertGreaterThan(layer.at(x: 104, y: 60).w, layer.at(x: 116, y: 60).w, "still lighter outside than in")
        // Each dab lays the average under the one before, so a trace does creep along
        XCTAssertLessThan(layer.at(x: 160, y: 60).w, 0.1, "little carried far along the stroke")
        XCTAssertEqual(layer.at(x: 160, y: 20).w, 0, accuracy: 0.001)
    }

    // MARK: - Engine integration

    func testUndoRestoresTheLayerExactly() throws {
        let harness = try canvasWithRedBlock()
        let before = harness.pixels(of: harness.drawingLayer.texture)
        _ = smudge(harness)
        harness.draw(StrokeFixtures.wave(from: CGPoint(x: 80, y: 60), length: 150, amplitude: 20, cycles: 1.5))
        let after = harness.pixels(of: harness.drawingLayer.texture)
        XCTAssertGreaterThan(worstDifference(before, after), 0.2)
        XCTAssertTrue(harness.viewModel.isDirty)

        harness.viewModel.performUndo(renderer: harness.renderer)
        XCTAssertEqual(worstDifference(harness.pixels(of: harness.drawingLayer.texture), before), 0)
        harness.viewModel.performRedo(renderer: harness.renderer)
        XCTAssertEqual(worstDifference(harness.pixels(of: harness.drawingLayer.texture), after), 0)
    }

    /// The result depends on the stroke, not on when frames happened to run.
    func testResultDoesNotDependOnFrameCadence() throws {
        func render(pointsPerFrame: Int) throws -> PixelGrid {
            let harness = try canvasWithRedBlock()
            _ = smudge(harness)
            harness.draw(StrokeFixtures.wave(from: CGPoint(x: 80, y: 60), length: 150, amplitude: 20, cycles: 1.5),
                         pointsPerFrame: pointsPerFrame)
            return harness.pixels(of: harness.drawingLayer.texture)
        }
        XCTAssertLessThan(worstDifference(try render(pointsPerFrame: 2), try render(pointsPerFrame: 40)), 0.002)
    }

    /// While the pen is down the composite shows the layer as the smudge has changed it, and
    /// every pixel it changes is recomposited.
    func testCompositeFollowsTheSmudgeWhileDrawing() throws {
        let harness = try canvasWithRedBlock()
        _ = smudge(harness, strength: 1)
        let points = StrokeFixtures.line(from: CGPoint(x: 90, y: 60), to: CGPoint(x: 200, y: 60), pressure: 1...1)
        harness.renderer.beginStroke()
        harness.viewModel.beginStroke(point: points[0])
        points.dropFirst().forEach(harness.viewModel.continueStroke(point:))
        let shown = harness.composite()
        XCTAssertGreaterThan(shown.at(x: 170, y: 60).w, 0.9, "the smear is on screen before pen-up")
        harness.renderer.finalizeStroke()
        harness.viewModel.endStroke()

        // Starting over with a full recomposite gives the same picture.
        let fresh = try EngineHarness(width: harness.width, height: harness.height)
        let copy = fresh.context.commandQueue.makeCommandBuffer()!
        let blit = copy.makeBlitCommandEncoder()!
        blit.copy(from: harness.drawingLayer.texture, to: fresh.drawingLayer.texture)
        blit.endEncoding()
        copy.commit()
        copy.waitUntilCompleted()
        XCTAssertLessThan(worstDifference(harness.composite(), fresh.composite()), 0.002)
    }

    func testSymmetryCopiesTheSmudge() throws {
        let harness = try EngineHarness(width: 200, height: 100)
        harness.fill(harness.drawingLayer, red: 1, green: 0, blue: 0)
        _ = smudge(harness, colorRate: 1)
        harness.viewModel.currentColor = blue
        harness.viewModel.symmetryMode = .horizontal
        harness.draw(StrokeFixtures.line(from: CGPoint(x: 20, y: 50), to: CGPoint(x: 80, y: 50), pressure: 1...1))
        let layer = harness.pixels(of: harness.drawingLayer.texture)
        XCTAssertGreaterThan(layer.at(x: 50, y: 50).z, 0.9)
        XCTAssertGreaterThan(layer.at(x: 150, y: 50).z, 0.9, "mirrored")
        XCTAssertEqual(layer.at(x: 100, y: 20).z, 0, accuracy: 0.01)
    }

    /// The carried paint keeps its layout: what was above the brush's path stays above it.
    func testSmearedPaintKeepsItsLayout() throws {
        let harness = try EngineHarness(width: 260, height: 120)
        harness.select(.hardRound)
        harness.viewModel.brushSize = 40
        harness.viewModel.currentColor = red
        harness.draw(StrokeFixtures.line(from: CGPoint(x: 10, y: 80), to: CGPoint(x: 90, y: 80), pressure: 1...1))
        harness.viewModel.currentColor = blue
        harness.draw(StrokeFixtures.line(from: CGPoint(x: 10, y: 40), to: CGPoint(x: 90, y: 40), pressure: 1...1))
        _ = smudge(harness, strength: 1, size: 60)
        harness.draw(StrokeFixtures.line(from: CGPoint(x: 90, y: 60), to: CGPoint(x: 200, y: 60), pressure: 1...1))
        let layer = harness.pixels(of: harness.drawingLayer.texture)
        for x in [130, 140, 150, 160] {
            let above = layer.at(x: x, y: 72), below = layer.at(x: x, y: 48)
            XCTAssertGreaterThan(above.x, 0.5, "red carried along above the path at x = \(x)")
            XCTAssertLessThan(above.z, 0.1, "x = \(x)")
            XCTAssertGreaterThan(below.z, 0.5, "blue carried along below it at x = \(x)")
            XCTAssertLessThan(below.x, 0.1, "x = \(x)")
        }
    }

    func testSmudgeSettingsSurviveTheBrushFile() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ArtsySmudge-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let library = BrushLibrary(directory: directory)
        let file = directory.appendingPathComponent("smudge.artsybrush")
        try library.export(.smudge, to: file)
        XCTAssertTrue(try String(contentsOf: file, encoding: .utf8).contains("\"smearing\""))
        // The built-in's id is taken, so this comes back as a copy; the settings are the point
        XCTAssertEqual(try library.importBrush(from: file).rendering, BrushDescriptor.smudge.rendering)
    }

    func testStrengthIsNormalisedToSpacing() {
        // Smearing: the same paint carries the same distance whatever the spacing
        let smear = StampSettings.Smudge(mode: .smearing, strength: 0.75, colorRate: 0)
        XCTAssertEqual(pow(smear.depositFraction(spacing: 0.05), 20), pow(smear.depositFraction(spacing: 0.25), 4), accuracy: 1e-5)
        XCTAssertEqual(smear.depositFraction(spacing: 0.25), 0.75, accuracy: 1e-6)
        XCTAssertEqual(StampSettings.Smudge(mode: .smearing, strength: 1, colorRate: 0).depositFraction(spacing: 0.05), 1)
        XCTAssertEqual(StampSettings.Smudge(mode: .smearing, strength: 0, colorRate: 0).depositFraction(spacing: 0.05), 0)

        // Dulling: the same share of the original is left after a diameter
        let dull = StampSettings.Smudge(mode: .dulling, strength: 0.75, colorRate: 0)
        XCTAssertEqual(pow(1 - dull.depositFraction(spacing: 0.05), 20), pow(1 - dull.depositFraction(spacing: 0.25), 4), accuracy: 1e-5)
        XCTAssertEqual(dull.depositFraction(spacing: 0.25), 0.75, accuracy: 1e-6)
        XCTAssertEqual(StampSettings.Smudge(mode: .dulling, strength: 1, colorRate: 0).depositFraction(spacing: 0.05), 1)
    }
}
