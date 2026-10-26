import AppKit
import SwiftUI
import simd
import ArtsyEngine

/// The paper's lean as a pad: the dot is where the paper leans to, and water runs that
/// way. Put the pen where the lean should be and the dot follows; the centre is level,
/// and a touch near it snaps to level. Takes its own drags inside a `PenScrollView`.
final class TiltPadView: NSView, PenDragTarget {
    static let side: CGFloat = 104
    /// The dot's reach stops this short of the edge.
    static let inset: CGFloat = 14
    /// Within this of the centre, as a fraction of the reach, is level.
    static let levelZone: Float = 0.1

    var tilt: SIMD2<Float> = .zero { didSet { needsDisplay = true } }
    var onChange: (SIMD2<Float>) -> Void = { _ in }

    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        let path = NSBezierPath(roundedRect: bounds, xRadius: 8, yRadius: 8)
        NSColor(Chrome.control).setFill()
        path.fill()
        NSColor(Chrome.hairline).setStroke()
        let cross = NSBezierPath()
        cross.move(to: NSPoint(x: bounds.midX, y: Self.inset))
        cross.line(to: NSPoint(x: bounds.midX, y: bounds.maxY - Self.inset))
        cross.move(to: NSPoint(x: Self.inset, y: bounds.midY))
        cross.line(to: NSPoint(x: bounds.maxX - Self.inset, y: bounds.midY))
        cross.lineWidth = 1
        cross.stroke()
        let reach = bounds.width / 2 - Self.inset
        NSBezierPath(ovalIn: NSRect(x: bounds.midX - reach, y: bounds.midY - reach, width: reach * 2, height: reach * 2)).stroke()
        let dot = NSPoint(x: bounds.midX + CGFloat(tilt.x) * reach, y: bounds.midY + CGFloat(tilt.y) * reach)
        (tilt == .zero ? NSColor(Chrome.secondaryText) : NSColor.controlAccentColor).setFill()
        NSBezierPath(ovalIn: NSRect(x: dot.x - 7, y: dot.y - 7, width: 14, height: 14)).fill()
    }

    override func mouseDown(with event: NSEvent) { lean(to: event) }
    override func mouseDragged(with event: NSEvent) { lean(to: event) }

    private func lean(to event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        let reach = bounds.width / 2 - Self.inset
        var lean = SIMD2(Float((point.x - bounds.midX) / reach), Float((point.y - bounds.midY) / reach))
        lean = simd_clamp(lean, SIMD2(repeating: -1), SIMD2(repeating: 1))
        if simd_length(lean) < Self.levelZone { lean = .zero }
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

/// The paper's lean, under Adjust: the pad, a word on where the lean is, and Level.
struct TiltControl: View {
    @ObservedObject var viewModel: CanvasViewModel

    static let height: CGFloat = TiltPadView.side + 8

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            TiltPad(tilt: $viewModel.canvasTilt)
                .frame(width: TiltPadView.side, height: TiltPadView.side)
            VStack(alignment: .leading, spacing: 4) {
                Text(Self.words(for: viewModel.canvasTilt))
                    .font(Chrome.font)
                    .foregroundColor(Chrome.text)
                Text("Water runs this way")
                    .font(Chrome.labelFont)
                    .foregroundColor(Chrome.secondaryText)
                Spacer(minLength: 0)
                Button(action: { viewModel.canvasTilt = .zero }) {
                    HStack(spacing: 8) {
                        Image(systemName: "level")
                            .font(.system(size: 17))
                        Text("Level")
                            .font(Chrome.font)
                    }
                    .frame(maxWidth: .infinity)
                    .frame(height: Chrome.target)
                    .background(RoundedRectangle(cornerRadius: 8).fill(Chrome.control))
                    .contentShape(RoundedRectangle(cornerRadius: 8))
                }
                .buttonStyle(.plain)
                .foregroundColor(viewModel.canvasTilt == .zero ? Chrome.secondaryText : Chrome.text)
                .help("Lay the paper flat")
            }
        }
        .frame(height: TiltPadView.side)
        .padding(.horizontal, 14)
        .padding(.bottom, 8)
    }

    /// "Level", or which way and how far: "→ 40%  ↓ 20%".
    static func words(for tilt: SIMD2<Float>) -> String {
        if tilt == .zero { return "Level" }
        var parts: [String] = []
        let x = Int((abs(tilt.x) * 100).rounded()), y = Int((abs(tilt.y) * 100).rounded())
        if x > 0 { parts.append("\(tilt.x > 0 ? "→" : "←") \(x)%") }
        if y > 0 { parts.append("\(tilt.y > 0 ? "↓" : "↑") \(y)%") }
        return parts.joined(separator: "  ")
    }
}
