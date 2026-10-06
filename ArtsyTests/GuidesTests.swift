import XCTest
import AppKit
@testable import Artsy

/// A grid and guide lines over the canvas, which the pen snaps to.
final class GuidesTests: XCTestCase {
    // MARK: - Snapping

    func testAGuideHoldsOneCoordinateWithinReachAtAnyZoom() {
        var guides = CanvasGuides()
        guides.verticals = [100]
        guides.horizontals = [50]
        XCTAssertEqual(guides.snapped(CGPoint(x: 104, y: 20), zoom: 1), CGPoint(x: 100, y: 20), "x held, y free")
        XCTAssertEqual(guides.snapped(CGPoint(x: 112, y: 20), zoom: 1), CGPoint(x: 112, y: 20), "out of reach")
        XCTAssertEqual(guides.snapped(CGPoint(x: 104, y: 20), zoom: 4), CGPoint(x: 104, y: 20), "8 screen points is 2 canvas px zoomed in")
        XCTAssertEqual(guides.snapped(CGPoint(x: 130, y: 54), zoom: 1), CGPoint(x: 130, y: 50), "y held")
        XCTAssertEqual(guides.snapped(CGPoint(x: 96, y: 54), zoom: 1), CGPoint(x: 100, y: 50), "both, at the crossing")
        guides.snapsToGuides = false
        XCTAssertEqual(guides.snapped(CGPoint(x: 104, y: 54), zoom: 1), CGPoint(x: 104, y: 54))
        XCTAssertFalse(guides.snapsAnything)
    }

    func testTheGridHoldsBothCoordinatesAndGuidesWinOverIt() {
        var guides = CanvasGuides()
        guides.showsGrid = true
        guides.snapsToGrid = true
        guides.gridSpacing = 64
        XCTAssertEqual(guides.snapped(CGPoint(x: 60, y: 126), zoom: 1), CGPoint(x: 64, y: 128))
        XCTAssertEqual(guides.snapped(CGPoint(x: 90, y: 100), zoom: 1), CGPoint(x: 90, y: 100), "well between lines")
        guides.showsGrid = false
        XCTAssertEqual(guides.snapped(CGPoint(x: 60, y: 126), zoom: 1), CGPoint(x: 60, y: 126), "a hidden grid does not snap")
        guides.showsGrid = true
        guides.verticals = [58]
        XCTAssertEqual(guides.snapped(CGPoint(x: 60, y: 126), zoom: 1), CGPoint(x: 58, y: 128), "the guide takes x, the grid y")
    }

    func testPickingUpMovingAndRemovingGuides() {
        var guides = CanvasGuides()
        guides.verticals = [100, 300]
        guides.horizontals = [50]
        XCTAssertEqual(guides.line(near: CGPoint(x: 303, y: 200), zoom: 1), .vertical(1))
        XCTAssertEqual(guides.line(near: CGPoint(x: 200, y: 47), zoom: 1), .horizontal(0))
        XCTAssertNil(guides.line(near: CGPoint(x: 200, y: 200), zoom: 1))
        XCTAssertEqual(guides.line(near: CGPoint(x: 102, y: 53), zoom: 1), .vertical(0), "the nearer of the two")
        guides.move(.vertical(1), to: CGPoint(x: 320, y: 999))
        XCTAssertEqual(guides.verticals, [100, 320])
        guides.remove(.horizontal(0))
        XCTAssertTrue(guides.horizontals.isEmpty)
        guides.remove(.horizontal(5))
    }

    // MARK: - Drawing along a guide

    func testAStrokeNearAGuideRunsExactlyAlongIt() throws {
        func ink(snapping: Bool) throws -> PixelGrid {
            let harness = try EngineHarness(width: 200, height: 200)
            harness.select(.hardRound)
            harness.viewModel.brushSize = 6
            harness.viewModel.guides.verticals = [100]
            harness.viewModel.guides.snapsToGuides = snapping
            // A vertical stroke that wanders 5 px either side of the guide
            let wobbly = StrokeFixtures.sampled(duration: 1) { t in
                (CGPoint(x: 100 + 5 * sin(t * 6 * .pi), y: 20 + 160 * t), 0.8)
            }
            harness.draw(wobbly)
            return harness.pixels(of: harness.drawingLayer.texture)
        }
        let snapped = try ink(snapping: true)
        for y in stride(from: 30, through: 170, by: 10) {
            XCTAssertGreaterThan(snapped.at(x: 100, y: y).w, 0.9, "ink on the guide at y = \(y)")
            XCTAssertEqual(snapped.at(x: 94, y: y).w, 0, accuracy: 0.001, "none 6 px to the left")
            XCTAssertEqual(snapped.at(x: 106, y: y).w, 0, accuracy: 0.001, "none 6 px to the right")
        }
        let free = try ink(snapping: false)
        XCTAssertTrue(stride(from: 30, through: 170, by: 10).contains { free.at(x: 94, y: $0).w > 0.5 || free.at(x: 106, y: $0).w > 0.5 },
                      "without snapping the wander shows")
    }

    // MARK: - The overlay

    func testTheOverlayDrawsTheGridAndTheGuides() throws {
        let viewModel = CanvasViewModel(canvasSize: CGSize(width: 400, height: 300))
        viewModel.guides.showsGrid = true
        viewModel.guides.gridSpacing = 64
        viewModel.guides.verticals = [100]
        viewModel.guides.horizontals = [150]
        // The canvas fills the view one to one
        viewModel.transform.scale = 1
        viewModel.transform.offset = CGPoint(x: -200, y: -150)
        let overlay = SelectionOverlayView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
        overlay.viewModel = viewModel
        func capture() throws -> NSBitmapImageRep {
            let rep = try XCTUnwrap(overlay.bitmapImageRepForCachingDisplay(in: overlay.bounds))
            overlay.cacheDisplay(in: overlay.bounds, to: rep)
            return rep
        }
        var rep = try capture()
        let scale = CGFloat(rep.pixelsWide) / 400
        func pixel(_ x: CGFloat, _ y: CGFloat) -> NSColor {
            // Bitmap rows run top-down; the view's y runs up
            rep.colorAt(x: Int(x * scale), y: Int((300 - y) * scale))!.usingColorSpace(.deviceRGB)!
        }
        let onGuide = pixel(100, 75)
        XCTAssertGreaterThan(onGuide.alphaComponent, 0.5, "the vertical guide is drawn")
        XCTAssertGreaterThan(onGuide.blueComponent, onGuide.redComponent + 0.2, "in teal")
        XCTAssertGreaterThan(pixel(250, 150).alphaComponent, 0.5, "the horizontal guide too")
        XCTAssertGreaterThan(pixel(64, 40).alphaComponent, 0.05, "a grid line, faint")
        XCTAssertEqual(pixel(40, 40).alphaComponent, 0, accuracy: 0.01, "nothing between lines")

        viewModel.guides = CanvasGuides()
        rep = try capture()
        XCTAssertEqual(pixel(100, 75).alphaComponent, 0, accuracy: 0.01, "cleared")
    }

    // MARK: - Documents

    func testGuidesSaveWithTheDocumentAndOlderDocumentsHaveNone() throws {
        let harness = try EngineHarness(width: 64, height: 64)
        harness.viewModel.guides.showsGrid = true
        harness.viewModel.guides.gridSpacing = 32
        harness.viewModel.guides.verticals = [20, 40]
        harness.viewModel.guides.horizontals = [10]
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("ArtsyGuides-\(UUID().uuidString).artsy")
        defer { try? FileManager.default.removeItem(at: url) }

        let saved = expectation(description: "saved")
        CanvasDocument.saveAsync(renderer: harness.renderer, viewModel: harness.viewModel, to: url) { result in
            if case .failure(let error) = result { XCTFail("\(error)") }
            saved.fulfill()
        }
        wait(for: [saved], timeout: 10)
        XCTAssertEqual(try CanvasDocument.load(from: url, metalContext: harness.context).viewModel.guides, harness.viewModel.guides)

        // A document from before guides existed has no key for them
        let jsonURL = url.appendingPathComponent("document.json")
        var json = try JSONSerialization.jsonObject(with: Data(contentsOf: jsonURL)) as! [String: Any]
        XCTAssertNotNil(json.removeValue(forKey: "guides"))
        try JSONSerialization.data(withJSONObject: json).write(to: jsonURL)
        XCTAssertEqual(try CanvasDocument.load(from: url, metalContext: harness.context).viewModel.guides, CanvasGuides())
    }
}
