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
        // Not whatever the saved preferences say
        viewModel.smoothingMode = .none
        viewModel.easesStrokesWithoutPressure = false

        // Never shown; the view only needs a window to convert event locations.
        window = NSWindow(contentRect: view.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = view
        // Events built from CGEvents carry screen coordinates; with the window at the
        // screen's origin those are window coordinates too.
        window.setFrameOrigin(.zero)
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

    /// Quartz event location for a canvas point (origin top-left of the main display).
    private func quartzLocation(ofCanvas point: CGPoint) -> CGPoint {
        let inView = viewModel.transform.canvasToView(point, viewSize: view.bounds.size)
        let onScreen = window.convertPoint(toScreen: view.convert(inView, to: nil))
        return CGPoint(x: onScreen.x, y: NSScreen.screens[0].frame.maxY - onScreen.y)
    }

    /// A mouse event carrying pen data, the way a tablet driver posts pen movement.
    private func pen(_ type: CGEventType, atCanvas point: CGPoint, pressure: Double,
                     tilt: CGPoint = .zero) throws -> NSEvent {
        let event = try XCTUnwrap(CGEvent(mouseEventSource: nil, mouseType: type,
                                          mouseCursorPosition: quartzLocation(ofCanvas: point), mouseButton: .left))
        event.setIntegerValueField(.mouseEventSubtype, value: Int64(CGEventMouseSubtype.tabletPoint.rawValue))
        event.setDoubleValueField(.mouseEventPressure, value: pressure)
        event.setDoubleValueField(.tabletEventPointPressure, value: pressure)
        event.setDoubleValueField(.tabletEventTiltX, value: tilt.x)
        event.setDoubleValueField(.tabletEventTiltY, value: tilt.y)
        return try XCTUnwrap(NSEvent(cgEvent: event))
    }

    /// A native tablet event: what arrives when only the pen's pressure changes.
    private func tabletPoint(atCanvas point: CGPoint, pressure: Double) throws -> NSEvent {
        let event = try XCTUnwrap(CGEvent(source: nil))
        event.type = .tabletPointer
        event.location = quartzLocation(ofCanvas: point)
        event.setDoubleValueField(.tabletEventPointPressure, value: pressure)
        return try XCTUnwrap(NSEvent(cgEvent: event))
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

    func testPenPressureSetsTheWidthOfAStroke() throws {
        // Hard Round at 12 px: 30% of full width at no pressure, 100% at full pressure.
        view.mouseDown(with: try pen(.leftMouseDown, atCanvas: CGPoint(x: 40, y: 128), pressure: 0.05))
        for step in 1...40 {
            let x = 40 + CGFloat(step) * 4
            view.mouseDragged(with: try pen(.leftMouseDragged, atCanvas: CGPoint(x: x, y: 128), pressure: Double(step) / 40))
        }
        view.mouseUp(with: try pen(.leftMouseUp, atCanvas: CGPoint(x: 200, y: 128), pressure: 0))
        view.draw()

        let drawn = composite()
        XCTAssertLessThan(drawn.at(x: 60, y: 128).x, 0.1, "the light end is drawn")
        XCTAssertGreaterThan(drawn.at(x: 60, y: 132).x, 0.9, "…but thin: 4 px off-centre is paper")
        XCTAssertLessThan(drawn.at(x: 190, y: 132).x, 0.1, "the firm end is wide enough to cover it")
    }

    /// Tilt reaches the brush: a pencil on its side makes a much broader mark.
    func testLeaningThePenShadesWithTheSideOfThePencil() throws {
        func widthOfStroke(tilt: CGPoint) throws -> Int {
            viewModel.currentBrush = .pencil
            viewModel.brushSize = 10
            view.mouseDown(with: try pen(.leftMouseDown, atCanvas: CGPoint(x: 40, y: 128), pressure: 0.8, tilt: tilt))
            for step in 1...30 {
                view.mouseDragged(with: try pen(.leftMouseDragged, atCanvas: CGPoint(x: 40 + CGFloat(step) * 5, y: 128),
                                                pressure: 0.8, tilt: tilt))
            }
            view.mouseUp(with: try pen(.leftMouseUp, atCanvas: CGPoint(x: 190, y: 128), pressure: 0, tilt: tilt))
            view.draw()
            let drawn = composite()
            let marked = (100...156).filter { drawn.at(x: 120, y: $0).x < 0.9 }
            view.performUndoAction()
            return (marked.max() ?? 0) - (marked.min() ?? 0)
        }
        let upright = try widthOfStroke(tilt: .zero)
        let leaning = try widthOfStroke(tilt: CGPoint(x: 0, y: 0.9))
        XCTAssertGreaterThan(upright, 4)
        XCTAssertGreaterThan(leaning, upright * 2, "upright \(upright) px, leaning \(leaning) px")
    }

    /// With the pen resting on the tablet, pressing harder sends tablet events, not drags.
    func testPressingHarderWithoutMovingGrowsTheDot() throws {
        let spot = CGPoint(x: 128, y: 128)
        view.mouseDown(with: try pen(.leftMouseDown, atCanvas: spot, pressure: 0.05))
        view.draw()
        XCTAssertGreaterThan(composite().at(x: 132, y: 128).x, 0.9, "a light touch leaves a small dot")

        view.tabletPoint(with: try tabletPoint(atCanvas: spot, pressure: 1.0))
        view.draw()
        XCTAssertLessThan(composite().at(x: 132, y: 128).x, 0.1, "pressing harder grows it")

        view.tabletPoint(with: try tabletPoint(atCanvas: spot, pressure: 0.1))
        view.mouseUp(with: try pen(.leftMouseUp, atCanvas: spot, pressure: 0))
        view.draw()
        XCTAssertLessThan(composite().at(x: 132, y: 128).x, 0.1, "easing off before lifting keeps it")
    }

    func testEveryPenSampleIsTakenWhileDrawing() throws {
        XCTAssertTrue(NSEvent.isMouseCoalescingEnabled)
        view.mouseDown(with: mouse(.leftMouseDown, atCanvas: CGPoint(x: 40, y: 128), time: 0))
        XCTAssertFalse(NSEvent.isMouseCoalescingEnabled, "AppKit must not merge pen samples mid-stroke")
        view.mouseUp(with: mouse(.leftMouseUp, atCanvas: CGPoint(x: 40, y: 128), time: 0.1))
        XCTAssertTrue(NSEvent.isMouseCoalescingEnabled)
    }

    /// With the canvas turned and mirrored on screen, a stroke still lands where the pen is.
    func testDrawingOnARotatedFlippedCanvasLandsUnderThePen() throws {
        let centre = CGPoint(x: view.bounds.midX, y: view.bounds.midY)
        viewModel.transform.rotate(by: 1.1, at: centre, viewSize: view.bounds.size)
        viewModel.transform.flip(at: centre, viewSize: view.bounds.size)
        view.draw()

        // `mouse(atCanvas:)` puts the event where that canvas point currently shows on screen
        view.mouseDown(with: mouse(.leftMouseDown, atCanvas: CGPoint(x: 60, y: 200), time: 0))
        for step in 1...20 {
            view.mouseDragged(with: mouse(.leftMouseDragged, atCanvas: CGPoint(x: 60 + CGFloat(step) * 7, y: 200 - CGFloat(step) * 5),
                                          time: Double(step) * 0.008))
        }
        view.mouseUp(with: mouse(.leftMouseUp, atCanvas: CGPoint(x: 200, y: 100), time: 0.17))
        view.draw()

        let drawn = composite()
        XCTAssertLessThan(drawn.at(x: 130, y: 150).x, 0.05, "on the line from (60,200) to (200,100)")
        XCTAssertLessThan(drawn.at(x: 190, y: 107).x, 0.05)
        XCTAssertEqual(drawn.at(x: 130, y: 190).x, 1, accuracy: 0.01, "nowhere else")
        XCTAssertEqual(drawn.at(x: 60, y: 100).x, 1, accuracy: 0.01)
    }

    /// A proximity event names the pen; the canvas then uses that pen's saved pressure curve.
    func testEachPenBringsItsOwnPressureCurve() throws {
        let prefs = AppPreferences.shared
        let savedCurves = prefs.pressureCurves
        let savedPen = TabletEventHandler.currentPenID
        defer {
            prefs.pressureCurves = savedCurves
            TabletEventHandler.currentPenID = savedPen
        }
        let penID: UInt64 = 0xA11CE
        prefs.pressureCurves[String(penID, radix: 16)] = .firm
        viewModel.pressureCurve = .linear

        let event = try XCTUnwrap(CGEvent(source: nil))
        event.type = .tabletProximity
        event.setIntegerValueField(.tabletProximityEventVendorUniqueID, value: Int64(penID))
        event.setIntegerValueField(.tabletProximityEventPointerType, value: 1)   // pen
        event.setIntegerValueField(.tabletProximityEventEnterProximity, value: 1)
        TabletEventHandler.handleProximity(event: try XCTUnwrap(NSEvent(cgEvent: event)))
        NotificationCenter.default.post(name: .tabletProximityChanged, object: nil)

        XCTAssertEqual(TabletEventHandler.currentPenID, penID)
        XCTAssertEqual(viewModel.pressureCurve, .firm)

        // An unknown pen gets the linear curve
        let other = try XCTUnwrap(CGEvent(source: nil))
        other.type = .tabletProximity
        other.setIntegerValueField(.tabletProximityEventVendorUniqueID, value: 0xB0B)
        other.setIntegerValueField(.tabletProximityEventPointerType, value: 1)
        other.setIntegerValueField(.tabletProximityEventEnterProximity, value: 1)
        TabletEventHandler.handleProximity(event: try XCTUnwrap(NSEvent(cgEvent: other)))
        NotificationCenter.default.post(name: .tabletProximityChanged, object: nil)
        XCTAssertEqual(viewModel.pressureCurve, .linear)
    }

    func testBrushCursorIsARingTheSizeOfTheBrush() {
        let cursor = BrushCursor.cursor(diameter: 40)
        XCTAssertEqual(cursor.image.size, NSSize(width: 44, height: 44), "40 pt ring plus a 2 pt margin")
        XCTAssertEqual(cursor.hotSpot, NSPoint(x: 22, y: 22))
        XCTAssertTrue(BrushCursor.cursor(diameter: 40.3) === cursor, "cached per whole point")

        let tiny = BrushCursor.cursor(diameter: 2)
        XCTAssertFalse(tiny === cursor)
        XCTAssertTrue(tiny === BrushCursor.cursor(diameter: 5000), "too small or too large for a ring: a crosshair")
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
