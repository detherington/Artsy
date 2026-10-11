import XCTest
import AppKit
import SwiftUI
@testable import Artsy

/// The chrome around the canvas, driven the way a pen drives it: taps and drags.
final class ShellTests: XCTestCase {
    private var window: NSWindow!

    override func tearDown() {
        window?.orderOut(nil)
        window?.contentView = nil
        window = nil
    }

    private func show(_ view: NSView, size: NSSize) {
        window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = view
        window.setFrameOrigin(.zero)
        // On screen: a SwiftUI view takes a click only through the window's dispatch, and
        // only while the window is showing
        window.orderFront(nil)
        view.layoutSubtreeIfNeeded()
    }

    private var pressedView: NSView?

    /// A mouse event delivered as AppKit delivers it: the mouse down to the view under it,
    /// the drag and the lift to that same view.
    private func send(_ type: NSEvent.EventType, at point: NSPoint, time: TimeInterval) {
        let event = NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: time, windowNumber: window.windowNumber,
                                       context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
        switch type {
        case .leftMouseDown:
            pressedView = window.contentView?.hitTest(point)
            pressedView?.mouseDown(with: event)
        case .leftMouseDragged:
            pressedView?.mouseDragged(with: event)
        default:
            pressedView?.mouseUp(with: event)
            pressedView = nil
        }
    }

    /// The chrome animates into place on a window that is showing; wait for it.
    private func settle(_ view: NSView) {
        RunLoop.main.run(until: Date().addingTimeInterval(0.35))
        view.layoutSubtreeIfNeeded()
    }

    private func canvas() throws -> (CanvasView, CanvasViewModel) {
        let context = EngineHarness.sharedContext
        let viewModel = CanvasViewModel(canvasSize: CGSize(width: 256, height: 256))
        viewModel.recorder = nil
        let view = CanvasView(frame: NSRect(x: 0, y: 0, width: 400, height: 300), device: context.device)
        try view.configure(context: context, viewModel: viewModel)
        return (view, viewModel)
    }

    /// A list a pen can scroll by dragging it, whose rows a pen can still tap.
    func testATapLandsOnARowAndADragScrollsTheList() throws {
        let taps = Taps()
        let host = NSHostingView(rootView: DragScroll {
            VStack(spacing: 0) {
                ForEach(0..<30, id: \.self) { row in
                    Button(action: { taps.rows.append(row) }) {
                        Text("Row \(row)")
                            .frame(maxWidth: .infinity, minHeight: 44)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
        })
        show(host, size: NSSize(width: 300, height: 220))
        let scroll = try XCTUnwrap(host.firstDescendant(of: PenScrollView.self))
        XCTAssertGreaterThan(scroll.documentView?.frame.height ?? 0, 1000, "thirty rows of 44")

        // A tap on the second row from the top (window coordinates go up)
        send(.leftMouseDown, at: NSPoint(x: 150, y: 220 - 66), time: 1)
        send(.leftMouseUp, at: NSPoint(x: 150, y: 220 - 66), time: 1.1)
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        XCTAssertEqual(taps.rows, [1], "the tap reached the row")

        // A drag upwards: the list scrolls, and no row is tapped. Slow, so no momentum.
        let before = scroll.contentView.bounds.origin.y
        send(.leftMouseDown, at: NSPoint(x: 150, y: 60), time: 2)
        send(.leftMouseDragged, at: NSPoint(x: 150, y: 100), time: 4)
        send(.leftMouseDragged, at: NSPoint(x: 150, y: 140), time: 6)
        send(.leftMouseUp, at: NSPoint(x: 150, y: 140), time: 8)
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        XCTAssertEqual(scroll.contentView.bounds.origin.y - before, 80, accuracy: 1, "the content went with the pen")
        XCTAssertEqual(taps.rows, [1], "and nothing was tapped")

        // A wobble under the threshold is still a tap
        send(.leftMouseDown, at: NSPoint(x: 150, y: 200), time: 10)
        send(.leftMouseDragged, at: NSPoint(x: 152, y: 198), time: 10.05)
        send(.leftMouseUp, at: NSPoint(x: 152, y: 198), time: 10.1)
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        XCTAssertEqual(taps.rows.count, 2, "a second row tapped")
    }

    /// The Layers dock needs a wide window and the user's say-so; the chrome goes together,
    /// leaving the canvas the whole window and a pill in the corner.
    func testTheLayersDockNeedsAWideWindowAndTheChromeGoesTogether() throws {
        let (canvasView, viewModel) = try canvas()
        viewModel.isLayersDocked = true
        let layout = MainLayout(canvasView: canvasView, viewModel: viewModel, previewRenderer: nil)
        show(layout, size: NSSize(width: 1800, height: 900))
        XCTAssertTrue(layout.isDockShown)
        let pill = try XCTUnwrap(layout.firstDescendant(of: NSHostingView<ChromePillView>.self))
        XCTAssertTrue(pill.isHidden, "the pill is for the chrome's absence")
        XCTAssertEqual(canvasView.frame.width, 1800 - Chrome.railWidth - Chrome.dockWidth, accuracy: 0.5)
        XCTAssertEqual(canvasView.frame.height, 900 - Chrome.barHeight, accuracy: 0.5)

        window.setContentSize(NSSize(width: 1200, height: 900))
        settle(layout)
        XCTAssertFalse(layout.isDockShown, "too narrow for a dock")
        XCTAssertEqual(canvasView.frame.width, 1200 - Chrome.railWidth, accuracy: 0.5)

        window.setContentSize(NSSize(width: 1800, height: 900))
        settle(layout)
        XCTAssertTrue(layout.isDockShown, "wide again")

        viewModel.isLayersDocked = false
        settle(layout)
        XCTAssertFalse(layout.isDockShown, "undocked")
        XCTAssertEqual(canvasView.frame.width, 1800 - Chrome.railWidth, accuracy: 0.5)
        viewModel.isLayersDocked = true

        viewModel.toggleChrome()
        settle(layout)
        XCTAssertFalse(layout.isDockShown)
        XCTAssertEqual(canvasView.frame.width, 1800, accuracy: 0.5, "the canvas has the window")
        XCTAssertEqual(canvasView.frame.height, 900, accuracy: 0.5)
        XCTAssertFalse(pill.isHidden, "the way back is in the corner")

        viewModel.toggleChrome()
        settle(layout)
        XCTAssertTrue(layout.isDockShown)
        XCTAssertTrue(pill.isHidden)
        XCTAssertEqual(canvasView.frame.height, 900 - Chrome.barHeight, accuracy: 0.5)
    }

    /// Tab on the canvas hides the chrome and brings it back.
    func testTabTogglesTheChromeFromTheCanvas() throws {
        let (canvasView, viewModel) = try canvas()
        let layout = MainLayout(canvasView: canvasView, viewModel: viewModel, previewRenderer: nil)
        show(layout, size: NSSize(width: 1200, height: 800))
        let tab = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber,
                                   context: nil, characters: "\t", charactersIgnoringModifiers: "\t", isARepeat: false, keyCode: 48)!
        canvasView.keyDown(with: tab)
        XCTAssertTrue(viewModel.isChromeHidden)
        canvasView.keyDown(with: tab)
        XCTAssertFalse(viewModel.isChromeHidden)
    }

    /// The size pill spreads the small sizes out; the opacity pill is even.
    func testThePillsMapTheTrackToTheirRanges() {
        XCTAssertEqual(ValuePill.value(at: 0, in: 1...200, logarithmic: true), 1, accuracy: 0.001)
        XCTAssertEqual(ValuePill.value(at: 1, in: 1...200, logarithmic: true), 200, accuracy: 0.01)
        XCTAssertEqual(ValuePill.value(at: 0.5, in: 1...200, logarithmic: true), 14.14, accuracy: 0.01, "halfway is the geometric middle")
        XCTAssertEqual(ValuePill.position(of: 14.14, in: 1...200, logarithmic: true), 0.5, accuracy: 0.001)
        XCTAssertEqual(ValuePill.value(at: 1.5, in: 1...200, logarithmic: true), 200, "dragging past the end stays at the end")
        XCTAssertEqual(ValuePill.value(at: -0.2, in: 1...200, logarithmic: true), 1)
        XCTAssertEqual(ValuePill.value(at: 0.5, in: 0.05...1, logarithmic: false), 0.525, accuracy: 0.001)
        XCTAssertEqual(ValuePill.position(of: 0.525, in: 0.05...1, logarithmic: false), 0.5, accuracy: 0.001)
    }
}

final class Taps: ObservableObject {
    @Published var rows: [Int] = []
}

extension NSView {
    func firstDescendant<T: NSView>(of type: T.Type) -> T? {
        for subview in subviews {
            if let match = subview as? T { return match }
            if let match = subview.firstDescendant(of: type) { return match }
        }
        return nil
    }
}

