import AppKit
import SwiftUI

/// A scroll view that scrolls when its content is dragged, the way a list on a phone
/// does, so a pen can scroll it. A pen's drag reaches AppKit as a mouse drag, not a
/// scroll wheel, and a plain `NSScrollView` (or SwiftUI's `ScrollView`) sits still under
/// it. Here a tap still lands on whatever is under it; a drag of more than
/// `dragThreshold` scrolls instead, and after the pen lifts the content keeps the pen's
/// speed for a moment. A pen held still for `holdDuration` is a right-click on what is
/// under it, so a context menu opens for a pen with no second button. The wheel and the
/// scroller work as ever.
final class PenScrollView: NSScrollView {
    static let dragThreshold: CGFloat = 6
    static let holdDuration: TimeInterval = 0.5

    private var pressed: (down: NSEvent, moves: [NSEvent])?
    private var hold: Timer?
    private var dragging = false
    private var lastDrag: (y: CGFloat, time: TimeInterval)?
    /// Points a second, up positive.
    private var velocity: CGFloat = 0
    private var momentum: Timer?
    private var forwarding = false

    override init(frame: NSRect) {
        super.init(frame: frame)
        setUp()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setUp()
    }

    private func setUp() {
        drawsBackground = false
        hasVerticalScroller = true
        hasHorizontalScroller = false
        autohidesScrollers = true
        scrollerStyle = .overlay
        horizontalScrollElasticity = .none
    }

    /// The content's events come here first, so a drag can be told from a tap before
    /// anything under it hears of either.
    override func hitTest(_ point: NSPoint) -> NSView? {
        guard let hit = super.hitTest(point) else { return nil }
        if forwarding { return hit }
        if let scroller = verticalScroller, hit === scroller || hit.isDescendant(of: scroller) { return hit }
        return hit.isDescendant(of: contentView) ? self : hit
    }

    // While a tap is being forwarded, the view under it may hand an event it has no use
    // for back up the responder chain, which leads here: on it goes, past this view.

    override func mouseDown(with event: NSEvent) {
        if forwarding { super.mouseDown(with: event); return }
        stopMomentum()
        pressed = (event, [])
        dragging = false
        lastDrag = (event.locationInWindow.y, event.timestamp)
        velocity = 0
        let timer = Timer(timeInterval: Self.holdDuration, repeats: false) { [weak self] _ in self?.holdFired() }
        RunLoop.main.add(timer, forMode: .common)
        hold = timer
    }

    override func mouseDragged(with event: NSEvent) {
        if forwarding { super.mouseDragged(with: event); return }
        guard pressed != nil else { return }
        let point = event.locationInWindow
        if !dragging {
            pressed?.moves.append(event)
            let start = pressed!.down.locationInWindow
            guard abs(point.y - start.y) >= Self.dragThreshold || abs(point.x - start.x) >= Self.dragThreshold else { return }
            dragging = true
            cancelHold()
        }
        if let last = lastDrag {
            let dy = point.y - last.y
            scrollContent(by: dy)
            let dt = event.timestamp - last.time
            if dt > 0 { velocity = velocity * 0.4 + (dy / CGFloat(dt)) * 0.6 }
        }
        lastDrag = (point.y, event.timestamp)
    }

    override func mouseUp(with event: NSEvent) {
        if forwarding { super.mouseUp(with: event); return }
        cancelHold()
        guard let pressed else { return }
        let wasDragging = dragging
        self.pressed = nil
        dragging = false
        lastDrag = nil
        if wasDragging {
            startMomentum()
        } else {
            forward(pressed.down, pressed.moves, event)
        }
    }

    /// A tap: the events go to the view under it, as if it had had them all along. They go
    /// through the application's dispatch, as the originals did, so a SwiftUI view's own
    /// handling (which is not only its `mouseDown`) sees them; `hitTest` lets them past.
    private func forward(_ down: NSEvent, _ moves: [NSEvent], _ up: NSEvent) {
        forwarding = true
        defer { forwarding = false }
        for event in [down] + moves + [up] {
            NSApp.sendEvent(event)
        }
    }

    private func cancelHold() {
        hold?.invalidate()
        hold = nil
    }

    /// The pen has been held still: what is under it gets a right-click, and the lift that
    /// follows is nobody's business.
    private func holdFired() {
        hold = nil
        guard let pressed, !dragging else { return }
        self.pressed = nil
        lastDrag = nil
        guard let window = pressed.down.window ?? window else { return }
        forwarding = true
        defer { forwarding = false }
        for type in [NSEvent.EventType.rightMouseDown, .rightMouseUp] {
            if let event = NSEvent.mouseEvent(with: type, location: pressed.down.locationInWindow, modifierFlags: [],
                                              timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                                              context: nil, eventNumber: 0, clickCount: 1, pressure: 1) {
                NSApp.sendEvent(event)
            }
        }
    }

    /// Move the content with the pen: `dy` is the pen's movement in window points, up
    /// positive. In a flipped document (SwiftUI's is) the origin grows downwards.
    func scrollContent(by dy: CGFloat) {
        guard let document = documentView else { return }
        let clip = contentView
        let maxY = max(0, document.frame.height - clip.bounds.height)
        let direction: CGFloat = document.isFlipped ? 1 : -1
        var origin = clip.bounds.origin
        origin.y = min(maxY, max(0, origin.y + direction * dy))
        clip.scroll(to: origin)
        reflectScrolledClipView(clip)
    }

    private func startMomentum() {
        guard abs(velocity) > 30 else { return }
        let timer = Timer(timeInterval: 1.0 / 60, repeats: true) { [weak self] timer in
            guard let self else { timer.invalidate(); return }
            self.scrollContent(by: self.velocity / 60)
            self.velocity *= 0.94
            if abs(self.velocity) < 20 { self.stopMomentum() }
        }
        RunLoop.main.add(timer, forMode: .common)
        momentum = timer
    }

    private func stopMomentum() {
        momentum?.invalidate()
        momentum = nil
    }
}

/// SwiftUI content in a `PenScrollView`: a list a pen can scroll. Takes the width it is
/// given; its height is the content's.
struct DragScroll<Content: View>: NSViewRepresentable {
    let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    func makeNSView(context: Context) -> PenScrollView {
        let scroll = PenScrollView()
        let host = NSHostingView(rootView: content)
        host.sizingOptions = [.intrinsicContentSize]
        host.translatesAutoresizingMaskIntoConstraints = false
        scroll.documentView = host
        NSLayoutConstraint.activate([
            host.leadingAnchor.constraint(equalTo: scroll.contentView.leadingAnchor),
            host.trailingAnchor.constraint(equalTo: scroll.contentView.trailingAnchor),
            host.topAnchor.constraint(equalTo: scroll.contentView.topAnchor),
        ])
        return scroll
    }

    func updateNSView(_ scroll: PenScrollView, context: Context) {
        (scroll.documentView as? NSHostingView<Content>)?.rootView = content
    }
}
