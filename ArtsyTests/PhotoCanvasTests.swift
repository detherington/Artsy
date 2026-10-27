import XCTest
import ImageIO
import UniformTypeIdentifiers
@testable import Artsy
@testable import ArtsyEngine

/// A canvas from a photo: the photo turned the right way up and held to the largest
/// canvas, and placed as the first layer under the one that is drawn on.
final class PhotoCanvasTests: XCTestCase {
    /// A JPEG `width` × `height` whose top-left quarter is red and the rest blue, tagged
    /// with an EXIF `orientation`.
    private func photo(width: Int, height: Int, orientation: Int) throws -> Data {
        let context = try XCTUnwrap(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                              space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(red: 0, green: 0, blue: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1))
        // CG's origin is at the bottom: the top-left quarter is the upper half of the left half
        context.fill(CGRect(x: 0, y: height / 2, width: width / 2, height: height / 2))
        let image = try XCTUnwrap(context.makeImage())
        let data = NSMutableData()
        let destination = try XCTUnwrap(CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, [kCGImagePropertyOrientation: orientation, kCGImageDestinationLossyCompressionQuality: 1.0] as CFDictionary)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        return data as Data
    }

    /// The colour at (`x`, `y`) of `image`, y down from the top.
    private func color(of image: CGImage, x: Int, y: Int) throws -> (r: Int, g: Int, b: Int) {
        var pixel = [UInt8](repeating: 0, count: 4)
        let context = try XCTUnwrap(CGContext(data: &pixel, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                                              space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.draw(image, in: CGRect(x: -x, y: -(image.height - 1 - y), width: image.width, height: image.height))
        return (Int(pixel[0]), Int(pixel[1]), Int(pixel[2]))
    }

    func testThePhotoIsTurnedUprightAndHeldToTheLargestCanvas() throws {
        // Stored 300 wide and 200 high, to be shown turned a quarter turn clockwise (6)
        let data = try photo(width: 300, height: 200, orientation: 6)
        let upright = try XCTUnwrap(PhotoCanvas.image(from: data, maxSide: 8192))
        XCTAssertEqual(upright.width, 200)
        XCTAssertEqual(upright.height, 300)
        // The stored top-left, red, turns to the top-right
        let topRight = try color(of: upright, x: 190, y: 10), topLeft = try color(of: upright, x: 10, y: 10)
        XCTAssertGreaterThan(topRight.r, 200, "red at the top right: \(topRight)")
        XCTAssertGreaterThan(topLeft.b, 200, "blue at the top left: \(topLeft)")
        // Held to the largest canvas, never grown
        let small = try XCTUnwrap(PhotoCanvas.image(from: data, maxSide: 150))
        XCTAssertEqual(max(small.width, small.height), 150)
        XCTAssertEqual(min(small.width, small.height), 100)
        let plain = try XCTUnwrap(PhotoCanvas.image(from: try photo(width: 120, height: 80, orientation: 1), maxSide: 8192))
        XCTAssertEqual(plain.width, 120)
        XCTAssertEqual(PhotoCanvas.canvasSize(for: plain), CGSize(width: 120, height: 80))
        XCTAssertEqual(PhotoCanvas.canvasSize(for: try XCTUnwrap(PhotoCanvas.image(from: try photo(width: 20, height: 20, orientation: 1), maxSide: 8192))),
                       CGSize(width: 64, height: 64), "no smaller than the smallest canvas")
        XCTAssertNil(PhotoCanvas.image(from: Data("not a photo".utf8), maxSide: 8192))
    }

    func testThePhotoIsTheFirstLayerUnderTheOneDrawnOn() throws {
        let harness = try EngineHarness(width: 120, height: 80)
        let image = try XCTUnwrap(PhotoCanvas.image(from: try photo(width: 120, height: 80, orientation: 1), maxSide: 8192))
        XCTAssertEqual(harness.layerStack.layers.map(\.name), ["Background", "Layer 1"])
        let index = try PhotoCanvas.place(image, named: "Harbour", in: harness.viewModel, renderer: harness.renderer)
        XCTAssertEqual(index, 1)
        XCTAssertEqual(harness.layerStack.layers.map(\.name), ["Background", "Harbour", "Layer 1"])
        XCTAssertEqual(harness.layerStack.activeLayerIndex, 2, "the empty layer above is the one to draw on")
        XCTAssertTrue(harness.viewModel.isDirty)
        // The grid reads in canvas coordinates, y up: the top left is (10, 70)
        let photo = harness.pixels(of: harness.layerStack.layers[1].texture)
        let red = photo.at(x: 10, y: 70), blue = photo.at(x: 110, y: 10)
        XCTAssertGreaterThan(red.x, 0.8, "red at the top left: \(red)")
        XCTAssertGreaterThan(blue.z, 0.8, "blue at the bottom right: \(blue)")
        XCTAssertEqual(red.w, 1, accuracy: 0.01, "opaque")
        let drawing = harness.pixels(of: harness.layerStack.layers[2].texture)
        XCTAssertEqual(drawing.at(x: 10, y: 10).w, 0, accuracy: 0.01, "nothing on the layer above")
    }
}
