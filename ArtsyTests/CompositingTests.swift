import XCTest
@testable import Artsy

/// Alpha handling from stroke shader to composite. Canvas textures are premultiplied;
/// these pin down the cases that went wrong when stroke shaders returned straight alpha.
final class CompositingTests: XCTestCase {

    /// A soft brush must fade out towards its edge whatever is underneath. With straight
    /// alpha in a premultiplied pipeline a white stroke over black showed solid white
    /// across its whole width.
    func testSoftLightBrushFadesOutOverDarkPaint() throws {
        let harness = try EngineHarness(width: 200, height: 120)
        harness.fill(harness.backgroundLayer, red: 0, green: 0, blue: 0)
        harness.select(.softRound)
        harness.viewModel.brushSize = 60
        harness.viewModel.currentColor = .white

        // Full pressure: Soft Round is then 60 px wide and fully opaque at its centre.
        harness.draw(StrokeFixtures.line(from: CGPoint(x: 20, y: 60), to: CGPoint(x: 180, y: 60), pressure: 1...1))
        let shown = harness.displayed()

        let centre = shown.at(x: 100, y: 60).x
        let halfway = shown.at(x: 100, y: 60 + 15).x
        let nearEdge = shown.at(x: 100, y: 60 + 26).x
        let outside = shown.at(x: 100, y: 60 + 40).x

        XCTAssertGreaterThan(centre, 0.95)
        XCTAssertEqual(halfway, 0.5, accuracy: 0.15, "halfway to the edge should be about half covered")
        XCTAssertLessThan(nearEdge, 0.1, "the edge of a soft stroke should be nearly transparent")
        XCTAssertEqual(outside, 0, accuracy: 0.001)
        XCTAssertGreaterThan(centre, halfway)
        XCTAssertGreaterThan(halfway, nearEdge)
    }

    /// Premultiplied colour never exceeds alpha, so nothing stored on a layer should pass 1.
    func testSoftStrokesKeepLayerValuesInRange() throws {
        let harness = try EngineHarness(width: 200, height: 120)
        harness.select(.softRound)
        harness.viewModel.brushSize = 50
        harness.viewModel.currentColor = StrokeColor(red: 0.5, green: 0.5, blue: 0.5, alpha: 1)
        for y in [40, 60, 80] {
            harness.draw(StrokeFixtures.line(from: CGPoint(x: 20, y: CGFloat(y)), to: CGPoint(x: 180, y: CGFloat(y))))
        }

        XCTAssertLessThanOrEqual(harness.pixels(of: harness.drawingLayer.texture).maxColourValue, 1.001)
        XCTAssertLessThanOrEqual(harness.composite().maxColourValue, 1.001)
    }

    /// A mid-grey soft stroke on white must darken the paper all the way out to its edge,
    /// not only where its coverage passes 50%.
    func testSoftGreyBrushOverWhiteIsAlphaWeighted() throws {
        let harness = try EngineHarness(width: 200, height: 120)
        harness.select(.softRound)
        harness.viewModel.brushSize = 60
        harness.viewModel.currentColor = StrokeColor(red: 0.5, green: 0.5, blue: 0.5, alpha: 1)
        harness.draw(StrokeFixtures.line(from: CGPoint(x: 20, y: 60), to: CGPoint(x: 180, y: 60), pressure: 1...1))

        let shown = harness.displayed()
        let coverage = harness.pixels(of: harness.drawingLayer.texture)
        for offset in [0, 8, 15, 22] {
            let alpha = coverage.at(x: 100, y: 60 + offset).w
            let expected = 0.5 * alpha + (1 - alpha)
            XCTAssertEqual(shown.at(x: 100, y: 60 + offset).x, expected, accuracy: 0.01,
                           "\(offset) px from the stroke centre")
        }
    }

    func testLayerOpacityScalesColourAndAlpha() throws {
        let harness = try EngineHarness(width: 32, height: 32)
        harness.fill(harness.backgroundLayer, red: 0, green: 0, blue: 0)
        harness.fill(harness.drawingLayer, red: 1, green: 0, blue: 0)
        harness.drawingLayer.opacity = 0.5

        let pixel = harness.composite().at(x: 16, y: 16)
        XCTAssertEqual(pixel.x, 0.5, accuracy: 0.01)
        XCTAssertEqual(pixel.y, 0, accuracy: 0.01)
        XCTAssertEqual(pixel.w, 1, accuracy: 0.01)
    }

    /// Blend modes need a backdrop; where there is none the layer shows as it is.
    func testBlendModesLeaveSourceUntouchedOverTransparency() throws {
        for mode in LayerBlendMode.allCases {
            let harness = try EngineHarness(width: 32, height: 32)
            harness.fill(harness.backgroundLayer, red: 0, green: 0, blue: 0, alpha: 0)
            harness.fill(harness.drawingLayer, red: 0.8, green: 0.4, blue: 0.2)
            harness.drawingLayer.blendMode = mode

            let pixel = harness.composite().at(x: 16, y: 16)
            XCTAssertEqual(pixel.x, 0.8, accuracy: 0.01, "\(mode) red")
            XCTAssertEqual(pixel.y, 0.4, accuracy: 0.01, "\(mode) green")
            XCTAssertEqual(pixel.z, 0.2, accuracy: 0.01, "\(mode) blue")
            XCTAssertEqual(pixel.w, 1, accuracy: 0.01, "\(mode) alpha")
        }
    }

    func testMultiplyLayerAtHalfOpacity() throws {
        let harness = try EngineHarness(width: 32, height: 32)
        harness.fill(harness.backgroundLayer, red: 0.5, green: 0.5, blue: 0.5)
        harness.fill(harness.drawingLayer, red: 0.5, green: 1, blue: 0)
        harness.drawingLayer.blendMode = .multiply
        harness.drawingLayer.opacity = 0.5

        // Multiply gives (0.25, 0.5, 0); at 50% that is halfway from the backdrop.
        let pixel = harness.composite().at(x: 16, y: 16)
        XCTAssertEqual(pixel.x, 0.375, accuracy: 0.01)
        XCTAssertEqual(pixel.y, 0.5, accuracy: 0.01)
        XCTAssertEqual(pixel.z, 0.25, accuracy: 0.01)
    }

    // MARK: - Opacity slider

    /// The slider caps the whole stroke: 50% black on white is mid-grey, and a stroke that
    /// crosses itself is no darker at the crossing.
    func testBrushOpacityCapsTheStroke() throws {
        let harness = try EngineHarness(width: 200, height: 200)
        harness.viewModel.brushSize = 20
        harness.viewModel.brushOpacity = 0.5

        // An X drawn without lifting: out along one diagonal, back along the other.
        let cross = StrokeFixtures.line(from: CGPoint(x: 40, y: 40), to: CGPoint(x: 160, y: 160), pressure: 1...1)
            + StrokeFixtures.line(from: CGPoint(x: 160, y: 40), to: CGPoint(x: 40, y: 160), pressure: 1...1)
                .map { StrokePoint(position: $0.position, pressure: $0.pressure, tiltX: 0, tiltY: 0,
                                   rotation: 0, timestamp: $0.timestamp + 1) }
        harness.draw(cross)

        let shown = harness.displayed()
        XCTAssertEqual(shown.at(x: 70, y: 70).x, 0.5, accuracy: 0.02, "single pass")
        XCTAssertEqual(shown.at(x: 100, y: 100).x, 0.5, accuracy: 0.02, "where the stroke crosses itself")
    }

    /// What is on screen while the pen is down must match what lands on the layer.
    func testStrokeLooksTheSameBeforeAndAfterPenUp() throws {
        let harness = try EngineHarness(width: 200, height: 120)
        harness.select(.softRound)
        harness.viewModel.brushSize = 40
        harness.viewModel.brushOpacity = 0.6
        harness.viewModel.currentColor = StrokeColor(red: 0.8, green: 0.2, blue: 0.1, alpha: 1)

        let points = StrokeFixtures.wave(from: CGPoint(x: 20, y: 60), length: 160, amplitude: 20, cycles: 1)
        harness.renderer.beginStroke()
        harness.viewModel.beginStroke(point: points[0])
        points.dropFirst().forEach(harness.viewModel.continueStroke(point:))
        let during = harness.composite()
        harness.renderer.finalizeStroke()
        harness.viewModel.endStroke()
        let after = harness.composite()

        var worst: Float = 0
        for i in during.values.indices { worst = max(worst, abs(during.values[i] - after.values[i])) }
        XCTAssertLessThan(worst, 0.005)
    }

    /// Samples that arrive between the last frame and pen-up still have to be drawn.
    func testStrokeReachesItsLastSample() throws {
        let harness = try EngineHarness(width: 200, height: 120)
        harness.viewModel.brushSize = 10
        // No frame is rendered between pen down and pen up.
        harness.draw(StrokeFixtures.line(from: CGPoint(x: 20, y: 60), to: CGPoint(x: 180, y: 60), pressure: 1...1),
                     pointsPerFrame: .max)

        XCTAssertLessThan(harness.displayed().at(x: 176, y: 60).x, 0.05)
    }

    func testEraserOpacityRemovesThatFraction() throws {
        let harness = try EngineHarness(width: 200, height: 120)
        harness.fill(harness.backgroundLayer, red: 1, green: 1, blue: 1, alpha: 0)
        harness.fill(harness.drawingLayer, red: 0, green: 0, blue: 0)
        harness.select(.eraser)
        harness.viewModel.brushSize = 40
        harness.viewModel.brushOpacity = 0.5

        harness.draw(StrokeFixtures.line(from: CGPoint(x: 20, y: 60), to: CGPoint(x: 180, y: 60), pressure: 1...1),
                     pointsPerFrame: .max)

        let layer = harness.pixels(of: harness.drawingLayer.texture)
        XCTAssertEqual(layer.at(x: 100, y: 60).w, 0.5, accuracy: 0.02)
        XCTAssertEqual(layer.at(x: 100, y: 110).w, 1, accuracy: 0.001, "outside the eraser's path")
    }
}
