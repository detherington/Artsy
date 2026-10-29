import XCTest
#if canImport(Artsy)
@testable import Artsy
#endif
@testable import ArtsyEngine

/// A pen with tilt but no force sensor, the USB-C Apple Pencil (the only Pencil the iPhone
/// Duo takes): its pressure from speed runs at a pen's pace, so quick handwriting keeps its
/// weight where a finger's would lie light; leaning it widens the mark without fading it;
/// it starts out with the Soft curve unless a curve was chosen for it; and the recording
/// says which it was.
final class PenWithoutPressureTests: XCTestCase {
    private func sample(_ x: CGFloat, at t: TimeInterval, tilt: SIMD2<Float> = .zero, pressure: Float = 0.7) -> StrokePoint {
        StrokePoint(position: CGPoint(x: x, y: 40), pressure: pressure, tiltX: tilt.x, tiltY: tilt.y, rotation: 0, timestamp: t)
    }

    /// A throwaway pen key with no pressure curve chosen for it, as the pen in hand, with
    /// the preferences and the key put back afterwards.
    private func withTestPen(_ body: () throws -> Void) throws {
        let prefs = AppPreferences.shared
        let savedCurves = prefs.pressureCurves, savedKey = CanvasViewModel.currentPenKey
        defer { prefs.pressureCurves = savedCurves; CanvasViewModel.currentPenKey = savedKey }
        prefs.pressureCurves["test-pen-without-pressure"] = nil
        CanvasViewModel.currentPenKey = { "test-pen-without-pressure" }
        try body()
    }

    func testAPensPaceKeepsMoreWeightThanAHandsAtTheSameSpeed() {
        let pen = PressureFromSpeed.Pace.pen
        XCTAssertEqual(PressureFromSpeed.pressure(atSpeed: 0, pace: .pen), 1, "still is full for a pen too")
        XCTAssertEqual(PressureFromSpeed.pressure(atSpeed: pen.fastSpeed, pace: .pen), pen.lightest, accuracy: 0.001)
        XCTAssertEqual(PressureFromSpeed.pressure(atSpeed: 10_000, pace: .pen), pen.lightest, accuracy: 0.001, "no lighter than lightest")
        let ladder = stride(from: Float(0), through: pen.fastSpeed, by: 250).map { PressureFromSpeed.pressure(atSpeed: $0, pace: .pen) }
        for (faster, slower) in zip(ladder.dropFirst(), ladder) { XCTAssertLessThan(faster, slower, "lighter the faster") }
        for speed in stride(from: Float(500), through: 4000, by: 250) {
            XCTAssertGreaterThan(PressureFromSpeed.pressure(atSpeed: speed, pace: .pen),
                                 PressureFromSpeed.pressure(atSpeed: speed, pace: .hand) + 0.1, "at \(speed) points a second")
        }
        // Quick handwriting, 1,000 to 2,000 points a second, keeps most of its weight
        XCTAssertGreaterThan(PressureFromSpeed.pressure(atSpeed: 1000, pace: .pen), 0.8)
        XCTAssertGreaterThan(PressureFromSpeed.pressure(atSpeed: 2000, pace: .pen), 0.65)
        XCTAssertLessThan(PressureFromSpeed.pressure(atSpeed: 2000, pace: .hand), 0.3, "where a finger lies light")
        // The hand's pace is the one the constants have always named
        XCTAssertEqual(PressureFromSpeed.Pace.hand.fastSpeed, PressureFromSpeed.fastSpeed)
        XCTAssertEqual(PressureFromSpeed.Pace.hand.lightest, PressureFromSpeed.lightest)
        XCTAssertEqual(PressureFromSpeed.pressure(atSpeed: 1000), PressureFromSpeed.pressure(atSpeed: 1000, pace: .hand))
    }

    func testAPenWithoutPressureTakesItsPressureFromAPensPaceAndAHandFromAHands() throws {
        try withTestPen {
            let cases: [(StrokeInput, PressureFromSpeed.Pace)] = [(.penWithoutPressure, .pen), (.hand, .hand)]
            for (input, pace) in cases {
                let harness = try EngineHarness(width: 120, height: 80)
                harness.select(.pencil)
                harness.viewModel.smoothingMode = .none
                harness.viewModel.pressureFromSpeed = true
                harness.renderer.beginStroke()
                harness.viewModel.beginStroke(point: sample(10, at: 0), input: input)
                XCTAssertEqual(harness.viewModel.strokeInput, input)
                XCTAssertFalse(harness.viewModel.strokeHasPressure)
                harness.viewModel.continueStroke(point: sample(30, at: 0.01))   // 2,000 px/s at zoom 1
                XCTAssertEqual(try XCTUnwrap(harness.viewModel.activePath?.samples.last?.pressure),
                               PressureFromSpeed.pressure(atSpeed: 2000, pace: pace), accuracy: 0.001, "\(input)")
                harness.renderer.finalizeStroke()
                harness.viewModel.endStroke()
            }
            // A pen with pressure of its own is left alone
            let harness = try EngineHarness(width: 120, height: 80)
            harness.select(.pencil)
            harness.viewModel.smoothingMode = .none
            harness.renderer.beginStroke()
            harness.viewModel.beginStroke(point: sample(10, at: 0, pressure: 0.3), input: .pen)
            XCTAssertTrue(harness.viewModel.strokeHasPressure)
            harness.viewModel.continueStroke(point: sample(30, at: 0.01, pressure: 0.3))
            XCTAssertEqual(try XCTUnwrap(harness.viewModel.activePath?.samples.last?.pressure), 0.3, accuracy: 0.001)
            harness.renderer.finalizeStroke()
            harness.viewModel.endStroke()
        }
    }

    func testLeaningAPenWithoutPressureWidensTheMarkWithoutFadingIt() throws {
        try withTestPen {
            func point(input: StrokeInput, tilt: SIMD2<Float>) throws -> InterpolatedPoint {
                let harness = try EngineHarness(width: 240, height: 80)
                harness.select(.pencil)   // broader, longer and lighter when flat
                harness.viewModel.smoothingMode = .none
                harness.viewModel.pressureFromSpeed = false
                harness.viewModel.easesStrokesWithoutPressure = false
                harness.viewModel.pressureCurve = .soft   // the same curve for every input here
                harness.renderer.beginStroke()
                harness.viewModel.beginStroke(point: sample(10, at: 0, tilt: tilt), input: input)
                for i in 1...20 { harness.viewModel.continueStroke(point: sample(10 + CGFloat(i) * 5, at: Double(i) * 0.01, tilt: tilt)) }
                let path = try XCTUnwrap(harness.viewModel.activePath)
                let middle = path.points[path.points.count / 2]
                harness.renderer.finalizeStroke()
                harness.viewModel.endStroke()
                return middle
            }
            let flat = SIMD2<Float>(0, -0.95)
            let upright = try point(input: .penWithoutPressure, tilt: .zero)
            let leaning = try point(input: .penWithoutPressure, tilt: flat)
            XCTAssertGreaterThan(leaning.width, upright.width * 1.5, "leaning widens: \(leaning.width) against \(upright.width)")
            XCTAssertGreaterThan(leaning.aspect, 1.3, "and lengthens the dab along the lean")
            XCTAssertEqual(leaning.opacity, upright.opacity, accuracy: 0.001, "but does not fade")
            let pen = try point(input: .pen, tilt: flat)
            XCTAssertLessThan(pen.opacity, upright.opacity * 0.9, "a pen with pressure fades as it leans, as before: \(pen.opacity) against \(upright.opacity)")
            XCTAssertEqual(pen.width, leaning.width, accuracy: 0.01, "and widens the same")
            let hand = try point(input: .hand, tilt: flat)
            XCTAssertEqual(hand.opacity, pen.opacity, accuracy: 0.001, "a hand's tilt, should it have any, is a pen's")
        }
    }

    func testAPenWithoutPressureStartsWithTheSoftCurveUnlessACurveWasChosen() throws {
        try withTestPen {
            let harness = try EngineHarness(width: 120, height: 80)
            let viewModel = harness.viewModel
            func stroke(_ input: StrokeInput) {
                harness.renderer.beginStroke()
                viewModel.beginStroke(point: sample(10, at: 0), input: input)
                viewModel.continueStroke(point: sample(20, at: 0.01))
                harness.renderer.finalizeStroke()
                viewModel.endStroke()
            }
            viewModel.pressureCurve = .linear
            stroke(.hand)
            XCTAssertEqual(viewModel.pressureCurve, .linear, "a mouse or a finger keeps the curve as it is")
            stroke(.pen)
            XCTAssertEqual(viewModel.pressureCurve, .linear, "so does a pen with pressure")
            stroke(.penWithoutPressure)
            XCTAssertEqual(viewModel.pressureCurve, .soft, "a pen that cannot press gets the curve that presses easily")
            viewModel.pressureCurve = .firm
            stroke(.penWithoutPressure)
            XCTAssertEqual(viewModel.pressureCurve, .firm, "a curve chosen in the panel stands")
            AppPreferences.shared.pressureCurves["test-pen-without-pressure"] = .linear
            viewModel.pressureCurve = .linear
            stroke(.penWithoutPressure)
            XCTAssertEqual(viewModel.pressureCurve, .linear, "Linear chosen for this pen stands too")
        }
    }

    func testTheRecordingSaysWhatDrewTheStroke() throws {
        try withTestPen {
            let harness = try EngineHarness(width: 120, height: 80)
            let viewModel = harness.viewModel
            viewModel.smoothingMode = .none
            viewModel.setStrokeRecording(true)
            defer { viewModel.setStrokeRecording(false) }
            harness.draw([sample(10, at: 0), sample(20, at: 0.01), sample(30, at: 0.02)], input: .penWithoutPressure)
            let recorded = try XCTUnwrap(viewModel.recorder?.recording.strokes.last)
            XCTAssertEqual(recorded.input, .penWithoutPressure)
            XCTAssertEqual(recorded.hasPressure, false)
            XCTAssertEqual(recorded.strokeInput, .penWithoutPressure)
            XCTAssertEqual(recorded.pressureCurve, .soft, "with the curve the stroke was drawn with")
            // A stroke that learns it has pressure after all is a pen's
            harness.renderer.beginStroke()
            viewModel.beginStroke(point: sample(10, at: 0), input: .penWithoutPressure)
            viewModel.strokeReportsPressure()
            XCTAssertEqual(viewModel.strokeInput, .pen)
            viewModel.continueStroke(point: sample(20, at: 0.01))
            harness.renderer.finalizeStroke()
            viewModel.endStroke()
            XCTAssertEqual(viewModel.recorder?.recording.strokes.last?.input, .pen)
            XCTAssertEqual(viewModel.recorder?.recording.strokes.last?.hasPressure, true)
            // Older recordings have no input: a hand where they say there was no pressure, else a pen
            var old = recorded
            old.input = nil
            XCTAssertEqual(old.strokeInput, .hand)
            old.hasPressure = nil
            XCTAssertEqual(old.strokeInput, .pen)
            // And it round-trips
            let data = try JSONEncoder().encode(recorded)
            XCTAssertEqual(try JSONDecoder().decode(RecordedStroke.self, from: data).strokeInput, .penWithoutPressure)
        }
    }

    /// On the canvas: the same quick line is heavier from a pen without pressure than from a finger.
    func testAQuickLineFromAPenWithoutPressureIsHeavierThanAFingers() throws {
        try withTestPen {
            func coverage(_ input: StrokeInput) throws -> Float {
                let harness = try EngineHarness(width: 240, height: 80)
                harness.select(.pencil)
                harness.viewModel.brushSize = 12
                harness.viewModel.currentColor = .black
                harness.viewModel.pressureFromSpeed = true
                harness.viewModel.easesStrokesWithoutPressure = false
                harness.viewModel.pressureCurve = .linear
                let points = StrokeFixtures.line(from: CGPoint(x: 20, y: 40), to: CGPoint(x: 220, y: 40), duration: 0.12)
                    .map { StrokePoint(position: $0.position, pressure: 0.7, tiltX: 0, tiltY: 0, rotation: 0, timestamp: $0.timestamp) }
                harness.draw(points, input: input)
                let layer = harness.pixels(of: harness.drawingLayer.texture)
                var sum: Float = 0
                for x in 60...180 { for y in 38...42 { sum += layer.at(x: x, y: y).w } }
                return sum / Float(121 * 5)
            }
            let pen = try coverage(.penWithoutPressure), finger = try coverage(.hand)
            XCTAssertGreaterThan(pen, finger * 1.5, "a pen keeps its weight at a pace that lightens a finger: \(pen) against \(finger)")
        }
    }
}
