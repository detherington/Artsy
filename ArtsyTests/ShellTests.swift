import XCTest
import AppKit
import SwiftUI
#if canImport(Artsy)
@testable import Artsy
#endif
@testable import ArtsyEngine

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
        viewModel.remembersGrades = false
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

    /// A pen held still on a row is a right-click on it, so a context menu can open for a
    /// pen with no second button; the lift after it taps nothing.
    func testAPenHeldStillIsARightClick() throws {
        let taps = Taps()
        let host = NSHostingView(rootView: DragScroll {
            VStack(spacing: 0) {
                ForEach(0..<10, id: \.self) { row in
                    Button(action: { taps.rows.append(row) }) {
                        Text("Row \(row)").frame(maxWidth: .infinity, minHeight: 44).contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
        })
        show(host, size: NSSize(width: 300, height: 220))
        var rightClicks: [NSPoint] = []
        let monitor = NSEvent.addLocalMonitorForEvents(matching: .rightMouseDown) { event in
            rightClicks.append(event.locationInWindow)
            return event
        }
        defer { if let monitor { NSEvent.removeMonitor(monitor) } }

        send(.leftMouseDown, at: NSPoint(x: 150, y: 220 - 66), time: 1)
        RunLoop.main.run(until: Date().addingTimeInterval(PenScrollView.holdDuration + 0.2))
        XCTAssertEqual(rightClicks.count, 1, "held still: a right-click where the pen is")
        XCTAssertEqual(rightClicks.first?.x ?? 0, 150, accuracy: 0.5)
        send(.leftMouseUp, at: NSPoint(x: 150, y: 220 - 66), time: 2)
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        XCTAssertEqual(taps.rows, [], "and the lift tapped nothing")

        // A tap lifted before the hold is a tap, and no right-click
        send(.leftMouseDown, at: NSPoint(x: 150, y: 220 - 66), time: 3)
        send(.leftMouseUp, at: NSPoint(x: 150, y: 220 - 66), time: 3.1)
        RunLoop.main.run(until: Date().addingTimeInterval(PenScrollView.holdDuration + 0.2))
        XCTAssertEqual(taps.rows, [1])
        XCTAssertEqual(rightClicks.count, 1)
    }

    /// The brush panel: a tap on a card picks the brush, a tap on the strip changes the
    /// category, and the menu's actions do what they say.
    func testTheBrushPanelPicksBrushesByCardAndCategory() throws {
        let (_, viewModel) = try canvas()
        let library = BrushLibrary.shared
        viewModel.currentBrush = .hardRound
        // Real previews only for a look at the panel; the taps do not need them
        let snapshotting = ProcessInfo.processInfo.environment["ARTSY_SNAPSHOT_DIR"] != nil
        let previews = BrushPreviewCache(renderer: snapshotting ? try? BrushPreview(context: EngineHarness.sharedContext, size: BrushPreviewCache.size) : nil,
                                          directory: nil)
        let panel = BrushPanelView(viewModel: viewModel, previews: previews, actions: ChromeActions(), dismiss: {})
        let host = NSHostingView(rootView: panel)
        show(host, size: NSSize(width: Chrome.panelWidth, height: 600))
        settle(host)
        if snapshotting { snapshot(host, named: "brush-panel") }

        // Hard Round is an inking brush, so the strip opens on Inking: the second card is the
        // second inking brush. Cards sit under the header (44) and the strip (56), inset 12,
        // 78 tall; the window's y runs upward.
        let inking = library.all.filter { $0.category == .inking && !library.isUserBrush($0) }
        let firstRow = 600 - (44 + 56 + 12 + BrushCard.height / 2)
        click(at: NSPoint(x: 250, y: firstRow))
        XCTAssertEqual(viewModel.currentBrush.id, inking[1].id, "the second card: \(viewModel.currentBrush.name)")
        XCTAssertEqual(viewModel.currentTool, .brush)

        // The strip: five equal pills across the inset width; Painting is the third
        let pill = (Chrome.panelWidth - 24) / 5
        click(at: NSPoint(x: 12 + pill * 2.5, y: 600 - 44 - 28))
        settle(host)
        click(at: NSPoint(x: 88, y: firstRow))
        let painting = library.all.filter { $0.category == .painting && !library.isUserBrush($0) }
        XCTAssertEqual(viewModel.currentBrush.id, painting[0].id, "the first painting brush: \(viewModel.currentBrush.name)")

        // Erasers is the fourth pill, and picking the eraser picks the tool
        click(at: NSPoint(x: 12 + pill * 3.5, y: 600 - 44 - 28))
        settle(host)
        click(at: NSPoint(x: 88, y: firstRow))
        XCTAssertEqual(viewModel.currentTool, .eraser)
    }

    func testTheBrushCardMenuDuplicatesResetsAndDeletes() throws {
        let (_, viewModel) = try canvas()
        let library = BrushLibrary.shared
        viewModel.currentBrush = .oil
        viewModel.brushSize = 77
        viewModel.smoothingStrength = 0.9
        BrushPanelActions.reset(.oil, viewModel: viewModel)
        XCTAssertEqual(viewModel.brushSize, BrushDescriptor.oil.baseSize)
        XCTAssertEqual(viewModel.smoothingStrength, BrushDescriptor.oil.smoothing)

        let before = library.userBrushes.count
        let copy = try XCTUnwrap(BrushPanelActions.duplicate(.oil, in: library, viewModel: viewModel))
        defer { try? library.remove(copy) }
        XCTAssertEqual(library.userBrushes.count, before + 1)
        XCTAssertEqual(viewModel.currentBrush.id, copy.id, "the copy is selected")
        XCTAssertTrue(BrushPanelCategory.mine.holds(copy, in: library), "and lives under Mine")
        XCTAssertFalse(BrushPanelCategory.painting.holds(copy, in: library))

        BrushPanelActions.delete(.oil, in: library, viewModel: viewModel)
        XCTAssertEqual(library.userBrushes.count, before + 1, "a built-in cannot be deleted")
        BrushPanelActions.delete(copy, in: library, viewModel: viewModel)
        XCTAssertEqual(library.userBrushes.count, before)
        XCTAssertEqual(viewModel.currentBrush.id, BrushDescriptor.hardRound.id, "Hard Round takes the deleted brush's place")
    }

    /// The colour panel: a tap on the square sets saturation and brightness, on the strip
    /// the hue, on Before the colour the panel opened with; a recent swatch picks and closes.
    func testTheColourPanelTakesTheSquareTheStripAndTheSwatches() throws {
        let (_, viewModel) = try canvas()
        let prefs = AppPreferences.shared
        let recentBefore = prefs.recentColors
        defer { prefs.recentColors = recentBefore }
        prefs.recentColors = ["FF0000"]
        let picked = Picked(color: StrokeColor(red: 0.2, green: 0.4, blue: 0.6, alpha: 1))
        var dismissed = 0
        let panel = ColorPanelView(color: Binding(get: { picked.color }, set: { picked.color = $0 }), viewModel: viewModel,
                                   dismiss: { dismissed += 1 })
        let host = NSHostingView(rootView: panel)
        show(host, size: NSSize(width: Chrome.panelWidth, height: 640))
        settle(host)
        if ProcessInfo.processInfo.environment["ARTSY_SNAPSHOT_DIR"] != nil { snapshot(host, named: "colour-panel") }

        // The square sits under the header (44) and 12 of padding, inset 12; window y runs up
        let square = ColorPanelView.squareSize, top: CGFloat = 44 + 12
        let hueBefore = ColorMath.hsb(of: picked.color).hue
        click(at: NSPoint(x: 12 + square * 0.75, y: 640 - (top + square * 0.25)))
        var hsb = ColorMath.hsb(of: picked.color)
        XCTAssertEqual(hsb.saturation, 0.75, accuracy: 0.03, "three quarters across the square")
        XCTAssertEqual(hsb.brightness, 0.75, accuracy: 0.03, "a quarter down it")
        XCTAssertEqual(hsb.hue, hueBefore, accuracy: 0.02, "the hue as it was")

        // The strip, beside the square, halfway down
        click(at: NSPoint(x: 12 + square + 12 + ColorPanelView.stripWidth / 2, y: 640 - (top + square * 0.5)))
        hsb = ColorMath.hsb(of: picked.color)
        XCTAssertEqual(hsb.hue, 0.5, accuracy: 0.03, "halfway round the hues")
        XCTAssertEqual(hsb.saturation, 0.75, accuracy: 0.03, "saturation and brightness as they were")

        // Before: the right half of the wells row under the square
        click(at: NSPoint(x: Chrome.panelWidth * 0.75, y: 640 - (top + square + 12 + 22)))
        XCTAssertEqual(picked.color, StrokeColor(red: 0.2, green: 0.4, blue: 0.6, alpha: 1), "back to where it opened")

        // A recent swatch, in the scrolling part under the fields and the Recent label
        let scrollTop = top + square + 12 + 44
        let swatchY = scrollTop + 44 + 30 + 6 + 16
        send(.leftMouseDown, at: NSPoint(x: 30, y: 640 - swatchY), time: 1)
        send(.leftMouseUp, at: NSPoint(x: 30, y: 640 - swatchY), time: 1.1)
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        XCTAssertEqual(ColorMath.hex(of: picked.color), "FF0000", "the swatch's colour")
        XCTAssertEqual(dismissed, 1, "and the panel closes for the pen to paint")
    }

    func testThePaletteKeepsWhatThePainterAddsAndDrops() {
        let prefs = AppPreferences.shared
        let before = prefs.paletteColors
        defer { prefs.paletteColors = before }
        prefs.paletteColors = ["000000", "FFFFFF"]
        let red = StrokeColor(red: 1, green: 0, blue: 0, alpha: 1)
        ColorPanelActions.add(red, to: prefs)
        XCTAssertEqual(prefs.paletteColors, ["000000", "FFFFFF", "FF0000"])
        ColorPanelActions.add(red, to: prefs)
        XCTAssertEqual(prefs.paletteColors.count, 3, "once")
        ColorPanelActions.replace(at: 1, with: StrokeColor(red: 0, green: 1, blue: 0, alpha: 1), in: prefs)
        XCTAssertEqual(prefs.paletteColors[1], "00FF00")
        ColorPanelActions.remove(at: 0, in: prefs)
        XCTAssertEqual(prefs.paletteColors, ["00FF00", "FF0000"])
        ColorPanelActions.remove(at: 9, in: prefs)
        XCTAssertEqual(prefs.paletteColors.count, 2, "nothing to remove there")
        XCTAssertEqual(AppPreferences.startingPalette.count, 16)
    }

    func testTheColourMathsRoundTrips() {
        let colour = StrokeColor(red: 0.85, green: 0.55, blue: 0.15, alpha: 1)
        XCTAssertEqual(ColorMath.hex(of: colour), "D98C26")
        let back = ColorMath.color(fromHex: "d98c26")!
        XCTAssertEqual(back.red, colour.red, accuracy: 0.003)
        XCTAssertEqual(back.blue, colour.blue, accuracy: 0.003)
        let (h, s, b) = ColorMath.hsb(of: colour)
        let again = ColorMath.color(hue: h, saturation: s, brightness: b)
        XCTAssertEqual(again.green, colour.green, accuracy: 0.003)
        var hue = 0.0
        XCTAssertTrue(ColorMath.applying(hue: "390", to: &hue))
        XCTAssertEqual(hue, 30.0 / 360, accuracy: 1e-6, "degrees wrap")
        XCTAssertFalse(ColorMath.applying(hue: "red", to: &hue))
        var value = 0.0
        XCTAssertTrue(ColorMath.applying(percent: "250", to: &value))
        XCTAssertEqual(value, 1, "percentages are clamped")
    }

    private final class Picked {
        var color: StrokeColor
        init(color: StrokeColor) { self.color = color }
    }

    /// The layers panel: its buttons add, copy, merge and delete; a tap on a row selects
    /// it, its eye hides it and its lock locks it.
    func testTheLayersPanelAddsCopiesMergesDeletesAndItsRowsTakeTaps() throws {
        let (view, viewModel) = try canvas()
        let layerStack = try XCTUnwrap(viewModel.layerStack)
        let panel = LayersPanelView(viewModel: viewModel, renderer: view.renderer, dockAvailable: false)
        let host = NSHostingView(rootView: panel)
        show(host, size: NSSize(width: Chrome.panelWidth, height: 520))
        settle(host)
        if ProcessInfo.processInfo.environment["ARTSY_SNAPSHOT_DIR"] != nil { snapshot(host, named: "layers-panel") }
        XCTAssertEqual(layerStack.layers.map(\.name), ["Background", "Layer 1"])

        // The buttons sit under the header (44), the blend row (44) and the opacity row
        // (44): a 52 pt row with four buttons spread across it
        let buttonsY: CGFloat = 520 - (44 + 88 + 26)
        func button(_ n: CGFloat) -> NSPoint { NSPoint(x: Chrome.panelWidth / 8 * (2 * n + 1), y: buttonsY) }
        click(at: button(0))
        XCTAssertEqual(layerStack.layers.map(\.name), ["Background", "Layer 1", "Layer 2"], "Add")
        XCTAssertEqual(layerStack.activeLayerIndex, 2)
        click(at: button(1))
        XCTAssertEqual(layerStack.layers.map(\.name), ["Background", "Layer 1", "Layer 2", "Layer 2 copy"], "Copy")
        XCTAssertEqual(layerStack.activeLayerIndex, 3)
        click(at: button(2))
        XCTAssertEqual(layerStack.layers.map(\.name), ["Background", "Layer 1", "Layer 2"], "Merge")
        click(at: button(3))
        XCTAssertEqual(layerStack.layers.map(\.name), ["Background", "Layer 1"], "Delete")
        settle(host)

        // The rows, the top layer first, start under the buttons' divider; a tap on the
        // second row (Paper) selects it
        let rowsTop: CGFloat = 44 + 88 + 52 + 6
        let row = LayersPanelContent.rowHeight + 2
        func rowY(_ n: CGFloat) -> CGFloat { 520 - (rowsTop + row * n + LayersPanelContent.rowHeight / 2) }
        send(.leftMouseDown, at: NSPoint(x: 150, y: rowY(1)), time: 1)
        send(.leftMouseUp, at: NSPoint(x: 150, y: rowY(1)), time: 1.1)
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        XCTAssertEqual(layerStack.activeLayerIndex, 0, "Paper selected")

        // The eye and the lock at the right end of the top row (Layer 1)
        let layer1 = layerStack.layers[1]
        let eyeX = Chrome.panelWidth - 12 - 36 - 8 - 18, lockX = Chrome.panelWidth - 12 - 18
        send(.leftMouseDown, at: NSPoint(x: eyeX, y: rowY(0)), time: 2)
        send(.leftMouseUp, at: NSPoint(x: eyeX, y: rowY(0)), time: 2.1)
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        XCTAssertFalse(layer1.isVisible, "hidden")
        send(.leftMouseDown, at: NSPoint(x: lockX, y: rowY(0)), time: 3)
        send(.leftMouseUp, at: NSPoint(x: lockX, y: rowY(0)), time: 3.1)
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        XCTAssertTrue(layer1.isLocked, "locked")
        XCTAssertEqual(layerStack.activeLayerIndex, 0, "neither button selected the row")
    }

    func testDuplicatingALayerCopiesItsPaintAndThickness() throws {
        let harness = try EngineHarness(width: 64, height: 64)
        harness.select(.oil)
        harness.viewModel.currentColor = StrokeColor(red: 0.9, green: 0.2, blue: 0.1, alpha: 1)
        harness.draw(StrokeFixtures.line(from: CGPoint(x: 10, y: 32), to: CGPoint(x: 54, y: 32), pressure: 1...1))
        let layerStack = harness.layerStack
        let actions = LayerActions(viewModel: harness.viewModel, layerStack: layerStack, renderer: harness.renderer)
        actions.duplicate(at: 1)
        XCTAssertEqual(layerStack.layers.map(\.name), ["Background", "Layer 1", "Layer 1 copy"])
        let copy = layerStack.layers[2]
        XCTAssertEqual(harness.pixels(of: copy.texture).values, harness.pixels(of: harness.drawingLayer.texture).values, "the paint")
        XCTAssertEqual(harness.heights(of: copy).values, harness.heights(of: harness.drawingLayer).values, "and the thickness")
        XCTAssertNil(copy.wetTexture, "the copy is dry")
        XCTAssertTrue(harness.viewModel.undoManager.canUndo, "a step to undo")
        harness.viewModel.performUndo(renderer: harness.renderer)
        XCTAssertEqual(layerStack.layers.count, 2, "and it undoes")
    }

    /// A drag that starts on a row's handle is the row's (to reorder); elsewhere it scrolls.
    func testADragFromTheHandleIsNotAScroll() throws {
        let host = NSHostingView(rootView: DragScroll(dragHandleWidth: 40) {
            VStack(spacing: 0) {
                ForEach(0..<30, id: \.self) { row in
                    Text("Row \(row)").frame(maxWidth: .infinity, minHeight: 44)
                }
            }
        })
        show(host, size: NSSize(width: 300, height: 220))
        let scroll = try XCTUnwrap(host.firstDescendant(of: PenScrollView.self))
        XCTAssertFalse(scroll.hitTest(NSPoint(x: 20, y: 100)) === scroll, "the handle strip is the content's")
        XCTAssertTrue(scroll.hitTest(NSPoint(x: 150, y: 100)) === scroll, "the rest is the scroll view's")
        send(.leftMouseDown, at: NSPoint(x: 150, y: 60), time: 1)
        send(.leftMouseDragged, at: NSPoint(x: 150, y: 140), time: 3)
        send(.leftMouseUp, at: NSPoint(x: 150, y: 140), time: 5)
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        XCTAssertEqual(scroll.contentView.bounds.origin.y, 80, accuracy: 1, "a drag on the row scrolls")
    }

    /// The Adjust panel: symmetry buttons set the mode, and Reset view does what it says.
    func testTheAdjustPanelSetsSymmetryAndResetsTheView() throws {
        let (_, viewModel) = try canvas()
        var resets = 0
        var actions = ChromeActions()
        actions.resetView = { resets += 1 }
        let host = NSHostingView(rootView: AdjustPanelView(viewModel: viewModel, actions: actions))
        show(host, size: NSSize(width: Chrome.panelWidth, height: 640))
        settle(host)
        if ProcessInfo.processInfo.environment["ARTSY_SNAPSHOT_DIR"] != nil { snapshot(host, named: "adjust-panel") }

        // Under the header (44) and the Symmetry label (30): four buttons across, then
        // the radial row; the list scrolls, so taps go through the scroll view
        let modesY: CGFloat = 44 + 30 + SymmetryButtons.modeHeight / 2
        let radialY: CGFloat = 44 + 30 + SymmetryButtons.modeHeight + 6 + 20
        func tap(_ x: CGFloat, _ y: CGFloat, _ t: TimeInterval) {
            send(.leftMouseDown, at: NSPoint(x: x, y: 640 - y), time: t)
            send(.leftMouseUp, at: NSPoint(x: x, y: 640 - y), time: t + 0.1)
            RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        }
        let inset: CGFloat = 14, slot = (Chrome.panelWidth - 28 - 18) / 4
        tap(inset + slot * 3.5, modesY, 1)
        XCTAssertEqual(viewModel.symmetryMode, .quad, "the fourth button")
        tap(inset + slot * 1.5, modesY, 2)
        XCTAssertEqual(viewModel.symmetryMode, .horizontal, "the second")
        // Radial pills share the row after a 60 pt label
        let pillSlot = (Chrome.panelWidth - 28 - 60 - 6 - 24) / 5
        tap(inset + 66 + pillSlot * 2.5, radialY, 3)
        XCTAssertEqual(viewModel.symmetryMode, .radial(6), "the third pill")
        tap(inset + slot * 0.5, modesY, 4)
        XCTAssertEqual(viewModel.symmetryMode, .off)

        // The Tilt section follows, its label and the pad with Level beside it; a drag on
        // the pad is the pad's, not a scroll, and lands the lean where the pen is
        let padTop: CGFloat = radialY + 20 + 8 + 30
        let padCentre = NSPoint(x: 14 + TiltPadMetrics.side / 2, y: padTop + TiltPadMetrics.side / 2)
        let reach = TiltPadMetrics.side / 2 - TiltPadMetrics.inset
        send(.leftMouseDown, at: NSPoint(x: padCentre.x, y: 640 - padCentre.y), time: 5)
        send(.leftMouseDragged, at: NSPoint(x: padCentre.x + reach * 0.5, y: 640 - padCentre.y - reach * 0.25), time: 5.1)
        send(.leftMouseUp, at: NSPoint(x: padCentre.x + reach * 0.5, y: 640 - padCentre.y - reach * 0.25), time: 5.2)
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        XCTAssertEqual(viewModel.canvasTilt.x, 0.5, accuracy: 0.05, "leaning right")
        XCTAssertEqual(viewModel.canvasTilt.y, 0.25, accuracy: 0.05, "and down")
        XCTAssertEqual(TiltControl.words(for: SIMD2(0.5, -0.25)), "→ 50%  ↑ 25%")
        XCTAssertEqual(TiltControl.words(for: .zero), "Level")
        let scroll = try XCTUnwrap(host.firstDescendant(of: PenScrollView.self))
        XCTAssertEqual(scroll.contentView.bounds.origin.y, 0, "the list did not scroll")
        // Level, at the bottom of the column beside the pad
        tap(14 + TiltPadMetrics.side + 12 + (Chrome.panelWidth - 28 - TiltPadMetrics.side - 12) / 2, padTop + TiltPadMetrics.side - 22, 6)
        XCTAssertEqual(viewModel.canvasTilt, .zero, "level again")

        // Reset view: the first row of the View section
        let resetY: CGFloat = padTop + TiltControl.height + 30 + 22
        tap(150, resetY, 7)
        XCTAssertEqual(resets, 1, "Reset view asked the window to reset")
    }

    /// The grade pills under the brush grid: a tap puts a graphite brush at that grade.
    func testThePencilGradePillsSetTheGrade() throws {
        let (_, viewModel) = try canvas()
        viewModel.currentBrush = .pencil
        let host = NSHostingView(rootView: PencilGradeRow(viewModel: viewModel))
        show(host, size: NSSize(width: Chrome.panelWidth, height: Chrome.target))
        settle(host)
        // The label, then seven pills sharing the width with six-point gaps between
        let pill = (Chrome.panelWidth - 28 - PencilGradeRow.labelWidth - 6 * 7) / 7
        func tap(_ grade: PencilGrade, _ t: TimeInterval) {
            let index = CGFloat(PencilGrade.shown.firstIndex(of: grade)!)
            click(at: NSPoint(x: 14 + PencilGradeRow.labelWidth + 6 + (pill + 6) * index + pill / 2, y: Chrome.target / 2))
        }
        tap(.b2, 1)
        XCTAssertEqual(viewModel.pencilGrade, .b2, "the fifth pill")
        tap(.h2, 2)
        XCTAssertEqual(viewModel.pencilGrade, .h2, "the first")
    }

    /// A slider in a panel's list is an AppKit slider underneath, and the pen on it is the
    /// slider's, not the scroll view's: the brush panel's Size slider takes the press and
    /// the drag after it rather than scrolling the list.
    func testAPanelSliderTakesThePenItself() throws {
        let (_, viewModel) = try canvas()
        viewModel.currentBrush = .hardRound
        viewModel.brushSize = 20
        let panel = BrushPanelView(viewModel: viewModel, previews: BrushPreviewCache(renderer: nil), actions: ChromeActions(), dismiss: {})
        let host = NSHostingView(rootView: panel)
        show(host, size: NSSize(width: Chrome.panelWidth, height: 700))
        settle(host)
        let slider = try XCTUnwrap(host.firstDescendant(of: NSSlider.self), "the quick settings' Size slider")
        let frame = slider.convert(slider.bounds, to: nil)
        XCTAssertTrue(window.contentView?.hitTest(NSPoint(x: frame.midX, y: frame.midY)) === slider, "the slider is hit, not the scroll view")

        // The press puts the knob under the pen, as the Mac's sliders do. The drag after it
        // is AppKit's own tracking, which looks at the real button and so cannot be fed
        // synthetic events here: two presses stand in for a drag from one end to the other.
        let low = NSPoint(x: frame.minX + 20, y: frame.midY), high = NSPoint(x: frame.maxX - 20, y: frame.midY)
        send(.leftMouseDown, at: low, time: 1)
        send(.leftMouseUp, at: low, time: 1.1)
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        XCTAssertLessThan(viewModel.brushSize, 10, "the knob went to the pen at the low end: \(viewModel.brushSize)")
        send(.leftMouseDown, at: high, time: 2)
        send(.leftMouseUp, at: high, time: 2.1)
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        XCTAssertGreaterThan(viewModel.brushSize, 30, "and at the high end: \(viewModel.brushSize)")
    }

    func testResettingTheViewMakesItUprightUnflippedAndFitted() throws {
        let (_, viewModel) = try canvas()
        let size = CGSize(width: 400, height: 300)
        viewModel.transform.scale = 3
        viewModel.rotateView(direction: 1, viewSize: size)
        viewModel.flipView(viewSize: size)
        XCTAssertTrue(viewModel.transform.isFlipped)
        viewModel.resetView(viewSize: size)
        XCTAssertFalse(viewModel.transform.isFlipped, "unflipped")
        XCTAssertEqual(viewModel.transform.rotation, 0, accuracy: 1e-6, "upright")
        var fitted = CanvasTransform()
        fitted.zoomToFit(canvasSize: viewModel.canvasSize, viewSize: size)
        XCTAssertEqual(viewModel.transform.scale, fitted.scale, accuracy: 1e-6, "fitted")
    }

    /// A canvas opened as the screen (the start screen's Full screen) starts with the
    /// chrome away and the pill up, the canvas the whole window; it fits edge to edge,
    /// now and after a reset; and Tab brings the chrome back.
    func testACanvasOpenedAsTheScreenStartsWithoutChromeAndFitsEdgeToEdge() throws {
        let (canvasView, viewModel) = try canvas()
        viewModel.isLayersDocked = false
        viewModel.fillScreen()
        let layout = MainLayout(canvasView: canvasView, viewModel: viewModel, previewRenderer: nil)
        show(layout, size: NSSize(width: 1800, height: 900))
        XCTAssertTrue(viewModel.isChromeHidden)
        XCTAssertEqual(canvasView.frame.width, 1800, accuracy: 0.5, "the canvas is the whole window")
        XCTAssertEqual(canvasView.frame.height, 900, accuracy: 0.5)
        let pill = try XCTUnwrap(layout.firstDescendant(of: NSHostingView<ChromePillView>.self))
        XCTAssertFalse(pill.isHidden, "the way back is up")

        let size = CGSize(width: 1376, height: 1032)
        viewModel.zoomToFit(viewSize: size)
        XCTAssertEqual(viewModel.transform.scale, 1032 / 256, accuracy: 1e-6, "edge to edge: the canvas is the view's height")
        XCTAssertEqual(viewModel.transform.canvasToView(.zero, viewSize: size).y, 0, accuracy: 1e-6)
        viewModel.transform.scale = 3
        viewModel.resetView(viewSize: size)
        XCTAssertEqual(viewModel.transform.scale, 1032 / 256, accuracy: 1e-6, "and after a reset of the view")

        viewModel.toggleChrome()
        settle(layout)
        XCTAssertEqual(canvasView.frame.width, 1800 - Chrome.railWidth, accuracy: 0.5, "Tab brings the chrome back")
        XCTAssertTrue(pill.isHidden)
    }

    /// The shortcut sheet lists what the keys do, and the number keys do what it says.
    func testTheShortcutSheetAndTheNumberKeysAgreeWithTheBrushPanel() throws {
        let host = NSHostingView(rootView: ShortcutsView())
        show(host, size: NSSize(width: 420, height: 640))
        settle(host)
        if ProcessInfo.processInfo.environment["ARTSY_SNAPSHOT_DIR"] != nil { snapshot(host, named: "shortcuts") }
        let keys = Shortcuts.groups.flatMap(\.entries).map(\.keys)
        XCTAssertEqual(Set(keys).count, keys.count, "no key listed twice")
        XCTAssertTrue(keys.contains("1 – 9"))

        let (view, viewModel) = try canvas()
        let library = BrushLibrary.shared.all
        func press(_ character: String, code: UInt16) {
            view.keyDown(with: NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                                                windowNumber: 0, context: nil, characters: character,
                                                charactersIgnoringModifiers: character, isARepeat: false, keyCode: code)!)
        }
        press("3", code: 20)
        XCTAssertEqual(viewModel.currentBrush.id, library[2].id, "3 is the third brush in the panel: \(viewModel.currentBrush.name)")
        XCTAssertEqual(viewModel.currentTool, .brush)
        press("9", code: 25)
        XCTAssertEqual(viewModel.currentBrush.id, library[8].id, "9 the ninth: \(viewModel.currentBrush.name)")
        press("b", code: 11)
        XCTAssertEqual(viewModel.currentBrush.id, BrushDescriptor.hardRound.id, "B is still Hard Round")
    }

    /// A click through the window's dispatch, which is the only way a SwiftUI view takes one.
    private func click(at point: NSPoint) {
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            let event = NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                           windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
            NSApp.sendEvent(event)
        }
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
    }

    /// The view as drawn, written where `ARTSY_SNAPSHOT_DIR` says, for a look.
    private func snapshot(_ view: NSView, named name: String) {
        guard let directory = ProcessInfo.processInfo.environment["ARTSY_SNAPSHOT_DIR"],
              let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: rep)
        guard let png = rep.representation(using: .png, properties: [:]) else { return }
        try? png.write(to: URL(fileURLWithPath: directory).appendingPathComponent("\(name).png"))
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
