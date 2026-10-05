import XCTest
import AppKit
import Metal
@testable import Artsy

/// End to end through the real view: mouse events in, pixels out. The other tests call the
/// renderer directly; this one covers the event handlers and `draw(in:)` around it.
final class CanvasViewTests: XCTestCase {
    private var window: NSWindow!
    private var view: CanvasView!
    private var viewModel: CanvasViewModel!

    override func setUpWithError() throws {
        let context = EngineHarness.sharedContext
        viewModel = CanvasViewModel(canvasSize: CGSize(width: 256, height: 256))
        viewModel.recorder = nil
        view = CanvasView(frame: NSRect(x: 0, y: 0, width: 400, height: 300), device: context.device)
        try view.configure(context: context, viewModel: viewModel)
        viewModel.currentBrush = .hardRound
        viewModel.brushSize = 12
        viewModel.currentColor = .black

        // Never shown; the view only needs a window to convert event locations.
        window = NSWindow(contentRect: view.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = view
        view.draw()   // first frame fits the canvas to the view
    }

    override func tearDown() {
        window.contentView = nil
        window = nil
        view = nil
        viewModel = nil
    }

    private func mouse(_ type: NSEvent.EventType, atCanvas point: CGPoint, time: TimeInterval) -> NSEvent {
        let inView = viewModel.transform.canvasToView(point, viewSize: view.bounds.size)
        return NSEvent.mouseEvent(
            with: type, location: view.convert(inView, to: nil), modifierFlags: [], timestamp: time,
            windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1
        )!
    }

    private func composite() -> PixelGrid {
        let context = EngineHarness.sharedContext
        let texture = view.renderer.compositeTexture!
        let readable = try! view.renderer.textureManager.makeSharedTexture(width: texture.width, height: texture.height)
        let commandBuffer = context.commandQueue.makeCommandBuffer()!
        let blit = commandBuffer.makeBlitCommandEncoder()!
        blit.copy(from: texture, to: readable)
        blit.endEncoding()
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()
        var half = [UInt16](repeating: 0, count: texture.width * texture.height * 4)
        half.withUnsafeMutableBytes {
            readable.getBytes($0.baseAddress!, bytesPerRow: texture.width * 8,
                              from: MTLRegionMake2D(0, 0, texture.width, texture.height), mipmapLevel: 0)
        }
        return PixelGrid(width: texture.width, height: texture.height, values: half.map { Float(Float16(bitPattern: $0)) })
    }

    /// The app is only a host here; it must not put its own windows or dialogs on screen.
    func testHostingTheTestsShowsNoWindows() {
        XCTAssertEqual(NSApp.windows.filter(\.isVisible).map(\.title), [])
    }

    func testDraggingTheMouseDrawsAStrokeAndUndoRemovesIt() throws {
        XCTAssertEqual(composite().at(x: 128, y: 128).x, 1, accuracy: 0.01, "the first frame should show blank paper")

        view.mouseDown(with: mouse(.leftMouseDown, atCanvas: CGPoint(x: 40, y: 128), time: 0))
        for step in 1...20 {
            let x = 40 + CGFloat(step) * 8
            view.mouseDragged(with: mouse(.leftMouseDragged, atCanvas: CGPoint(x: x, y: 128), time: Double(step) * 0.008))
            if step == 10 { view.draw() }   // a frame mid-stroke; the second half arrives after it
        }
        XCTAssertLessThan(composite().at(x: 80, y: 128).x, 0.3, "the stroke should be visible while the pen is down")

        view.mouseUp(with: mouse(.leftMouseUp, atCanvas: CGPoint(x: 200, y: 128), time: 0.17))
        XCTAssertFalse(viewModel.isDrawing)
        view.draw()

        let drawn = composite()
        // The mouse reports a fixed 0.7 pressure, which Hard Round draws at ~9.5 px wide.
        XCTAssertLessThan(drawn.at(x: 80, y: 128).x, 0.05, "start of the stroke")
        XCTAssertLessThan(drawn.at(x: 196, y: 128).x, 0.05, "samples after the last frame must still be drawn")
        XCTAssertEqual(drawn.at(x: 128, y: 150).x, 1, accuracy: 0.01, "away from the stroke")
        XCTAssertTrue(viewModel.isDirty)

        view.performUndoAction()
        view.draw()
        XCTAssertEqual(composite().at(x: 128, y: 128).x, 1, accuracy: 0.01, "undo should restore blank paper")
    }
}
