import XCTest
#if canImport(Artsy)
@testable import Artsy
#endif
@testable import ArtsyEngine

/// A Pencil's altitude and azimuth as the engine's two tilt components.
final class PencilTiltTests: XCTestCase {
    func testUprightIsNoLeanAndFlatIsFull() {
        let upright = PencilTilt.tilt(altitude: .pi / 2, azimuth: 0)
        XCTAssertEqual(upright.x, 0, accuracy: 1e-6)
        XCTAssertEqual(upright.y, 0, accuracy: 1e-6)
        let flat = PencilTilt.tilt(altitude: 0, azimuth: 0)
        XCTAssertEqual(flat.x, 1, accuracy: 1e-6, "leaning along +x")
        XCTAssertEqual(flat.y, 0, accuracy: 1e-6)
        let half = PencilTilt.tilt(altitude: .pi / 4, azimuth: 0)
        XCTAssertEqual(half.x, 0.5, accuracy: 1e-6, "halfway down, half the lean")
    }

    func testTheAzimuthTurnsTheLeanAndYComesOutUpwards() {
        // Leaning towards the bottom of a y-down screen is leaning towards -y in the
        // engine's y-up view space, as a tablet on the Mac reports it
        let down = PencilTilt.tilt(altitude: 0, azimuth: .pi / 2)
        XCTAssertEqual(down.x, 0, accuracy: 1e-6)
        XCTAssertEqual(down.y, -1, accuracy: 1e-6)
        let left = PencilTilt.tilt(altitude: 0, azimuth: .pi)
        XCTAssertEqual(left.x, -1, accuracy: 1e-6)
        XCTAssertEqual(left.y, 0, accuracy: 1e-6)
        let upInUpSpace = PencilTilt.tilt(altitude: 0, azimuth: .pi / 2, yDown: false)
        XCTAssertEqual(upInUpSpace.y, 1, accuracy: 1e-6, "measured in a y-up space, kept as is")
    }
}
