import XCTest
import simd
@testable import Artsy

final class CanvasTransformTests: XCTestCase {
    private let viewSize = CGSize(width: 800, height: 600)

    private func assertEqual(_ a: CGPoint, _ b: CGPoint, accuracy: CGFloat = 0.001, _ message: String = "",
                             file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(a.x, b.x, accuracy: accuracy, message, file: file, line: line)
        XCTAssertEqual(a.y, b.y, accuracy: accuracy, message, file: file, line: line)
    }

    func testViewAndCanvasRoundTripUnderRotationAndFlip() {
        var transform = CanvasTransform()
        transform.zoomToFit(canvasSize: CGSize(width: 2048, height: 2048), viewSize: viewSize)
        for (rotation, flipped) in [(CGFloat(0), false), (0.4, false), (-1.9, true), (.pi / 2, true)] {
            transform.rotation = rotation
            transform.isFlipped = flipped
            for canvas in [CGPoint(x: 0, y: 0), CGPoint(x: 1024, y: 1024), CGPoint(x: 2048, y: 300)] {
                let view = transform.canvasToView(canvas, viewSize: viewSize)
                assertEqual(transform.viewToCanvas(view, viewSize: viewSize), canvas, "rotation \(rotation), flipped \(flipped)")
            }
        }
    }

    func testRotatingAboutAPointKeepsItStill() {
        var transform = CanvasTransform()
        transform.zoomToFit(canvasSize: CGSize(width: 1000, height: 500), viewSize: viewSize)
        let pin = CGPoint(x: 600, y: 150)
        let under = transform.viewToCanvas(pin, viewSize: viewSize)

        transform.rotate(by: 0.7, at: pin, viewSize: viewSize)
        XCTAssertEqual(transform.rotation, 0.7, accuracy: 0.0001)
        assertEqual(transform.canvasToView(under, viewSize: viewSize), pin, "the pinned point stays under the pointer")

        // A point to the right of the pin ends up turned 0.7 rad counter-clockwise around it
        let right = transform.viewToCanvas(CGPoint(x: pin.x + 100, y: pin.y), viewSize: viewSize)
        transform.rotate(by: -0.7, at: pin, viewSize: viewSize)
        let back = transform.canvasToView(right, viewSize: viewSize)
        assertEqual(back, CGPoint(x: pin.x + 100 * cos(-0.7), y: pin.y + 100 * sin(-0.7)))
        XCTAssertEqual(transform.rotation, 0, accuracy: 0.0001)
    }

    func testFlippingMirrorsAboutThePointAndKeepsTheApparentTilt() {
        var transform = CanvasTransform()
        transform.zoomToFit(canvasSize: CGSize(width: 1000, height: 500), viewSize: viewSize)
        transform.rotate(by: 0.3, at: CGPoint(x: 400, y: 300), viewSize: viewSize)
        let pin = CGPoint(x: 400, y: 300)
        let under = transform.viewToCanvas(pin, viewSize: viewSize)
        let rightOfPin = transform.viewToCanvas(CGPoint(x: 500, y: 300), viewSize: viewSize)

        transform.flip(at: pin, viewSize: viewSize)
        XCTAssertTrue(transform.isFlipped)
        assertEqual(transform.canvasToView(under, viewSize: viewSize), pin)
        assertEqual(transform.canvasToView(rightOfPin, viewSize: viewSize), CGPoint(x: 300, y: 300), "what was to the right is now to the left")

        transform.flip(at: pin, viewSize: viewSize)
        XCTAssertFalse(transform.isFlipped)
        XCTAssertEqual(transform.rotation, 0.3, accuracy: 0.0001, "flipping twice restores the tilt")
        assertEqual(transform.canvasToView(rightOfPin, viewSize: viewSize), CGPoint(x: 500, y: 300))
    }

    func testDisplayMatrixAgreesWithThePointMapping() {
        var transform = CanvasTransform()
        transform.zoomToFit(canvasSize: CGSize(width: 1000, height: 500), viewSize: viewSize)
        transform.rotate(by: -0.9, at: CGPoint(x: 100, y: 500), viewSize: viewSize)
        transform.flip(at: CGPoint(x: 700, y: 100), viewSize: viewSize)
        let matrix = transform.transformMatrix(viewSize: viewSize)

        for canvas in [CGPoint(x: 0, y: 0), CGPoint(x: 1000, y: 500), CGPoint(x: 250, y: 400)] {
            let ndc = matrix * SIMD4<Float>(Float(canvas.x), Float(canvas.y), 0, 1)
            let view = transform.canvasToView(canvas, viewSize: viewSize)
            XCTAssertEqual(CGFloat(ndc.x), view.x / viewSize.width * 2 - 1, accuracy: 0.001)
            XCTAssertEqual(CGFloat(ndc.y), view.y / viewSize.height * 2 - 1, accuracy: 0.001)
        }
    }

    func testSettingRotationSnapsNearUprightAndWraps() {
        var transform = CanvasTransform()
        let pin = CGPoint(x: 400, y: 300)
        transform.setRotation(1 * .pi / 180, at: pin, viewSize: viewSize)
        XCTAssertEqual(transform.rotation, 0, "within two degrees of upright is upright")
        transform.setRotation(2 * .pi + 0.5, at: pin, viewSize: viewSize)
        XCTAssertEqual(transform.rotation, 0.5, accuracy: 0.0001)
        transform.rotate(by: .pi, at: pin, viewSize: viewSize)
        XCTAssertEqual(transform.rotation, 0.5 - .pi, accuracy: 0.0001, "kept within ±π")

        transform.isFlipped = true
        transform.zoomToFit(canvasSize: CGSize(width: 100, height: 100), viewSize: viewSize)
        XCTAssertEqual(transform.rotation, 0)
        XCTAssertFalse(transform.isFlipped, "fitting the canvas puts the view back upright")
    }
}
