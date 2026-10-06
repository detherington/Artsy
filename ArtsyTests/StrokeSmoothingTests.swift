import XCTest
@testable import Artsy

final class StrokeSmoothingTests: XCTestCase {
    private func sample(_ x: CGFloat, _ y: CGFloat, pressure: Float = 0.6, time: Double) -> StrokePoint {
        StrokePoint(position: CGPoint(x: x, y: y), pressure: pressure, tiltX: 0, tiltY: 0, rotation: 0, timestamp: time)
    }

    private func smoother(_ mode: SmoothingMode, strength: Float = 0.6, zoom: CGFloat = 1) -> StrokeSmoother {
        let smoother = StrokeSmoother()
        smoother.mode = mode
        smoother.strength = strength
        smoother.zoom = zoom
        smoother.begin()
        return smoother
    }

    /// Smoothing trails the pen. When the pen lifts, the stroke should still end where the
    /// pen was — except with the lazy brush, whose stroke ends where the string left it.
    func testCatchUpTakesTheStrokeToWhereThePenLifted() throws {
        for mode in SmoothingMode.allCases {
            let filter = smoother(mode, strength: 0.9)
            var last = sample(0, 0, time: 0)
            for step in 0...40 {
                last = sample(CGFloat(step) * 6, 50, time: Double(step) * 0.005)
                _ = filter.filter(last)
            }
            switch mode {
            case .oneEuro, .movingAverage:
                let catchUp = try XCTUnwrap(filter.catchUpPoint(), mode.rawValue)
                XCTAssertEqual(catchUp.position, last.position, mode.rawValue)
            case .none, .lazyBrush:
                XCTAssertNil(filter.catchUpPoint(), mode.rawValue)
            }
        }
    }

    func testNoCatchUpWhenTheFilterHasAlreadyArrived() {
        let filter = smoother(.oneEuro)
        for step in 0...200 {   // a second resting on one spot
            _ = filter.filter(sample(100, 100, time: Double(step) * 0.005))
        }
        XCTAssertNil(filter.catchUpPoint())
    }

    /// Pressure is steadied along with position; unsmoothed strokes keep the pen's pressure as is.
    func testPressureJitterIsReduced() {
        func roughness(_ mode: SmoothingMode) -> Float {
            let filter = smoother(mode)
            var total: Float = 0
            var previous: Float?
            for step in 0..<200 {
                let noisy: Float = 0.5 + (step % 2 == 0 ? 0.08 : -0.08)
                let out = filter.filter(sample(CGFloat(step) * 3, 50, pressure: noisy, time: Double(step) * 0.005))
                if let previous { total += abs(out.pressure - previous) }
                previous = out.pressure
            }
            return total
        }
        let raw = roughness(.none)
        for mode in [SmoothingMode.oneEuro, .lazyBrush, .movingAverage] {
            XCTAssertLessThan(roughness(mode), raw * 0.4, mode.rawValue)
        }
    }

    /// The adaptive filter works on speed across the screen, so the same hand movement is
    /// smoothed the same whether the canvas is zoomed in or out.
    func testAdaptiveSmoothingIsTheSameAtAnyZoom() {
        func filtered(zoom: CGFloat) -> [CGPoint] {
            let filter = smoother(.oneEuro, zoom: zoom)
            return (0...60).map { step in
                // The same path across the screen, expressed in canvas pixels at this zoom
                let screen = CGPoint(x: CGFloat(step) * 5, y: 40 * sin(CGFloat(step) * 0.3))
                let out = filter.filter(sample(screen.x / zoom, screen.y / zoom, time: Double(step) * 0.005))
                return CGPoint(x: out.position.x * zoom, y: out.position.y * zoom)
            }
        }
        for (a, b) in zip(filtered(zoom: 1), filtered(zoom: 4)) {
            XCTAssertEqual(a.x, b.x, accuracy: 0.001)
            XCTAssertEqual(a.y, b.y, accuracy: 0.001)
        }
    }

    /// More strength means more steadying of a slow, shaky line.
    func testStrengthControlsHowMuchAShakyLineIsSteadied() {
        func wobble(strength: Float) -> CGFloat {
            let filter = smoother(.oneEuro, strength: strength)
            var total: CGFloat = 0
            for step in 0..<300 {
                let jitter: CGFloat = step % 2 == 0 ? 1.5 : -1.5
                let out = filter.filter(sample(CGFloat(step) * 0.5, 50 + jitter, time: Double(step) * 0.005))
                total += abs(out.position.y - 50)
            }
            return total / 300
        }
        let light = wobble(strength: 0.2), medium = wobble(strength: 0.5), heavy = wobble(strength: 0.9)
        XCTAssertLessThan(light, 1.5)
        XCTAssertLessThan(medium, light)
        XCTAssertLessThan(heavy, medium)
        XCTAssertLessThan(heavy, 0.2)
    }
}
