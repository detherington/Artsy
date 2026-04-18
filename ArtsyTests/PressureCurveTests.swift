import XCTest
@testable import Artsy

final class PressureCurveTests: XCTestCase {

    func testLinearCurveEndpoints() {
        let curve = PressureCurve.linear
        XCTAssertEqual(curve.map(0.0), 0.0, accuracy: 0.01)
        XCTAssertEqual(curve.map(1.0), 1.0, accuracy: 0.01)
    }

    func testLinearCurveMidpoint() {
        let curve = PressureCurve.linear
        XCTAssertEqual(curve.map(0.5), 0.5, accuracy: 0.05)
    }

    func testSoftCurveReachesHighOutputEarly() {
        let curve = PressureCurve.soft
        // Soft curve should reach high output at moderate input
        let output = curve.map(0.5)
        XCTAssertGreaterThan(output, 0.6, "Soft curve should map 0.5 input to above 0.6")
    }

    func testFirmCurveRequiresHighInput() {
        let curve = PressureCurve.firm
        // Firm curve should have low output at moderate input
        let output = curve.map(0.5)
        XCTAssertLessThan(output, 0.4, "Firm curve should map 0.5 input to below 0.4")
    }

    func testPressureClamping() {
        let curve = PressureCurve.linear
        // Should clamp to [0, 1]
        XCTAssertGreaterThanOrEqual(curve.map(0.0), 0.0)
        XCTAssertLessThanOrEqual(curve.map(1.0), 1.0)
    }
}
