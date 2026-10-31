import AppKit
import SwiftUI
import simd
import ArtsyEngine

/// The paper's lean as a pad: the dot is where the paper leans to, and water runs that
/// way. Put the pen where the lean should be and the dot follows; the centre is level,
/// and a touch near it snaps to level. Takes its own drags inside a `PenScrollView`.
final class TiltPadView: NSView, PenDragTarget {
    var tilt: SIMD2<Float> = .zero { didSet { needsDisplay = true } }
    var onChange: (SIMD2<Float>) -> Void = { _ in }

    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        let inset = TiltPadMetrics.inset
        let path = NSBezierPath(rect: bounds)
        NSColor(Chrome.control).setFill()
        path.fill()
        NSColor(Chrome.hairline).setStroke()
        let cross = NSBezierPath()
        cross.move(to: NSPoint(x: bounds.midX, y: inset))
        cross.line(to: NSPoint(x: bounds.midX, y: bounds.maxY - inset))
        cross.move(to: NSPoint(x: inset, y: bounds.midY))
        cross.line(to: NSPoint(x: bounds.maxX - inset, y: bounds.midY))
        cross.lineWidth = 1
        cross.stroke()
        let reach = bounds.width / 2 - inset
        NSBezierPath(ovalIn: NSRect(x: bounds.midX - reach, y: bounds.midY - reach, width: reach * 2, height: reach * 2)).stroke()
        let dot = NSPoint(x: bounds.midX + CGFloat(tilt.x) * reach, y: bounds.midY + CGFloat(tilt.y) * reach)
        (tilt == .zero ? NSColor(Chrome.secondaryText) : NSColor(Chrome.accent)).setFill()
        NSBezierPath(ovalIn: NSRect(x: dot.x - 7, y: dot.y - 7, width: 14, height: 14)).fill()
    }

    override func mouseDown(with event: NSEvent) { lean(to: event) }
    override func mouseDragged(with event: NSEvent) { lean(to: event) }

    private func lean(to event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        let lean = TiltPadMetrics.lean(at: point, in: bounds)
        guard lean != tilt else { return }
        tilt = lean
        onChange(lean)
    }
}

/// `TiltPadView` for SwiftUI, bound to the lean.
struct TiltPad: NSViewRepresentable {
    @Binding var tilt: SIMD2<Float>

    func makeNSView(context: Context) -> TiltPadView {
        let pad = TiltPadView()
        pad.tilt = tilt
        pad.onChange = { tilt = $0 }
        return pad
    }

    func updateNSView(_ pad: TiltPadView, context: Context) {
        pad.onChange = { tilt = $0 }
        if pad.tilt != tilt { pad.tilt = tilt }
    }
}
