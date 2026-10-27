import XCTest
#if canImport(Artsy)
@testable import Artsy
#endif
@testable import ArtsyEngine

/// Pressure from speed, for a mouse, a finger or a pencil that reports none: still is full,
/// fast is light, the speed is the hand's on the screen, the change is smoothed, and a stroke drawn slowly comes out heavier than the
/// same stroke drawn quickly, while a pen with pressure of its own is left alone.
final class PressureFromSpeedTests: XCTestCase {
    func testStillIsFullAndFastIsLightInBetweenFallingAway() {
        XCTAssertEqual(PressureFromSpeed.pressure(atSpeed: 0), 1)
        XCTAssertEqual(PressureFromSpeed.pressure(atSpeed: PressureFromSpeed.fastSpeed), PressureFromSpeed.lightest, accuracy: 0.001)
        XCTAssertEqual(PressureFromSpeed.pressure(atSpeed: PressureFromSpeed.fastSpeed * 2), PressureFromSpeed.lightest, accuracy: 0.001, "no lighter than lightest")
        let ladder = stride(from: Float(0), through: PressureFromSpeed.fastSpeed, by: 250).map(PressureFromSpeed.pressure(atSpeed:))
        for (faster, slower) in zip(ladder.dropFirst(), ladder) { XCTAssertLessThan(faster, slower, "lighter the faster") }
        let walking = PressureFromSpeed.pressure(atSpeed: 500)
        XCTAssertTrue((0.6...0.9).contains(walking), "a walking pace presses firmly: \(walking)")
    }

    func testThePressureFollowsTheSpeedSmoothlyAndStartsFull() {
        var speed = PressureFromSpeed()
        func sample(_ x: CGFloat, at t: TimeInterval) -> StrokePoint {
            StrokePoint(position: CGPoint(x: x, y: 0), pressure: 0, tiltX: 0, tiltY: 0, rotation: 0, timestamp: t)
        }
        XCTAssertEqual(speed.pressure(for: sample(0, at: 0)), 1, "the pen has just landed")
        // A fast run: 3000 px/s for a quarter of a second
        var pressure: Float = 1
        for i in 1...50 { pressure = speed.pressure(for: sample(CGFloat(i) * 15, at: Double(i) * 0.005)) }
        XCTAssertLessThan(pressure, 0.3, "light at speed: \(pressure)")
        // Then still: the pressure comes back up over a moment, not at once
        let soon = speed.pressure(for: sample(750, at: 0.27))
        XCTAssertLessThan(soon, 0.6, "still for 20 ms, not yet pressing: \(soon)")
        var later: Float = 0
        for i in 1...40 { later = speed.pressure(for: sample(750, at: 0.27 + Double(i) * 0.01)) }
        XCTAssertGreaterThan(later, 0.95, "still for 400 ms, pressing fully: \(later)")
    }

    func testTheFirstMovementSetsTheSpeedAtOnceAndARestBeforeItIsStill() {
        var speed = PressureFromSpeed()
        func sample(_ x: CGFloat, at t: TimeInterval) -> StrokePoint {
            StrokePoint(position: CGPoint(x: x, y: 0), pressure: 0, tiltX: 0, tiltY: 0, rotation: 0, timestamp: t)
        }
        XCTAssertEqual(speed.pressure(for: sample(0, at: 0)), 1, "landed")
        XCTAssertEqual(speed.pressure(for: sample(0, at: 0.05)), 1, "resting before it moves")
        XCTAssertEqual(speed.pressure(for: sample(0, at: 0.10)), 1, "still resting")
        // The first movement, 1,000 points a second: its pressure, not a step down from full
        XCTAssertEqual(speed.pressure(for: sample(10, at: 0.11)), PressureFromSpeed.pressure(atSpeed: 1000), accuracy: 0.001,
                       "the first movement sets the speed outright")
        // From then on the speed is smoothed: a sudden doubling is not followed at once
        let next = speed.pressure(for: sample(30, at: 0.12))
        XCTAssertLessThan(next, PressureFromSpeed.pressure(atSpeed: 1000))
        XCTAssertGreaterThan(next, PressureFromSpeed.pressure(atSpeed: 2000), "smoothed, not stepped: \(next)")
    }

    func testTheSpeedIsTheHandsOnTheScreenWhateverTheZoom() {
        func pressure(zoom: Float, canvasStep: CGFloat) -> Float {
            var speed = PressureFromSpeed(zoom: zoom)
            var pressure: Float = 1
            for i in 0...30 {
                pressure = speed.pressure(for: StrokePoint(position: CGPoint(x: CGFloat(i) * canvasStep, y: 0), pressure: 0,
                                                           tiltX: 0, tiltY: 0, rotation: 0, timestamp: Double(i) * 0.01))
            }
            return pressure
        }
        // 10 points a frame, 1,000 points a second, as the hand feels it: the same pressure
        // whether a point is one canvas pixel or six
        XCTAssertEqual(pressure(zoom: 1, canvasStep: 10), pressure(zoom: 1 / 6, canvasStep: 60), accuracy: 0.001)
        XCTAssertEqual(pressure(zoom: 1, canvasStep: 10), PressureFromSpeed.pressure(atSpeed: 1000), accuracy: 0.001)
        // The same canvas motion on a phone, zoomed well out, is a slower hand: it presses harder
        XCTAssertGreaterThan(pressure(zoom: 1 / 6, canvasStep: 10), pressure(zoom: 1, canvasStep: 10) + 0.3)
    }

    /// On the canvas: the same line, drawn slowly and quickly, with a pencil whose touch
    /// decides how far into the paper it reaches.
    func testAStrokeWithoutPressureIsHeavierSlowThanFastAndAPenIsLeftAlone() throws {
        func coverage(duration: TimeInterval, hasPressure: Bool, substitute: Bool = true) throws -> Float {
            let harness = try EngineHarness(width: 240, height: 80)
            harness.select(.pencil)
            harness.viewModel.brushSize = 12
            harness.viewModel.currentColor = .black
            harness.viewModel.pressureFromSpeed = substitute
            harness.viewModel.easesStrokesWithoutPressure = false
            let points = StrokeFixtures.line(from: CGPoint(x: 20, y: 40), to: CGPoint(x: 220, y: 40), duration: duration)
                .map { StrokePoint(position: $0.position, pressure: 0.7, tiltX: 0, tiltY: 0, rotation: 0, timestamp: $0.timestamp) }
            harness.draw(points, hasPressure: hasPressure)
            let layer = harness.pixels(of: harness.drawingLayer.texture)
            var sum: Float = 0
            for x in 60...180 { for y in 38...42 { sum += layer.at(x: x, y: y).w } }
            return sum / Float(121 * 5)
        }
        let slow = try coverage(duration: 2.0, hasPressure: false), fast = try coverage(duration: 0.12, hasPressure: false)
        XCTAssertGreaterThan(slow, fast * 1.5, "slow presses harder: \(slow) against \(fast)")
        XCTAssertEqual(try coverage(duration: 2.0, hasPressure: false, substitute: false),
                       try coverage(duration: 0.12, hasPressure: false, substitute: false), accuracy: 0.02, "the same at any speed with the substitute off")
        XCTAssertEqual(try coverage(duration: 2.0, hasPressure: true), try coverage(duration: 0.12, hasPressure: true), accuracy: 0.02,
                       "a pen's own pressure is what it says, whatever the speed")
    }
}
