import SwiftUI
import simd
import ArtsyEngine

/// The tilt pad's geometry, shared by the Mac's pad view and the iPad's: the dot is where
/// the paper leans to, the centre is level, and a touch near the centre snaps to level.
enum TiltPadMetrics {
    static let side: CGFloat = 104
    /// The dot's reach stops this short of the edge.
    static let inset: CGFloat = 14
    /// Within this of the centre, as a fraction of the reach, is level.
    static let levelZone: Float = 0.1

    /// The lean a touch at `point` asks for, in a pad of `bounds` whose y runs down.
    static func lean(at point: CGPoint, in bounds: CGRect) -> SIMD2<Float> {
        let reach = bounds.width / 2 - inset
        var lean = SIMD2(Float((point.x - bounds.midX) / reach), Float((point.y - bounds.midY) / reach))
        lean = simd_clamp(lean, SIMD2(repeating: -1), SIMD2(repeating: 1))
        if simd_length(lean) < levelZone { lean = .zero }
        return lean
    }
}

/// The paper's lean, under Adjust: the pad, a word on where the lean is, and Level.
struct TiltControl: View {
    @ObservedObject var viewModel: CanvasViewModel

    static let height: CGFloat = TiltPadMetrics.side + 8

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            TiltPad(tilt: $viewModel.canvasTilt)
                .frame(width: TiltPadMetrics.side, height: TiltPadMetrics.side)
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
                        Text("level")
                            .font(Chrome.font)
                    }
                    .frame(maxWidth: .infinity)
                    .frame(height: Chrome.target)
                    .overlay(Rectangle().strokeBorder(Chrome.hairline, lineWidth: 1))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundColor(viewModel.canvasTilt == .zero ? Chrome.secondaryText : Chrome.text)
                .help("Lay the paper flat")
            }
        }
        .frame(height: TiltPadMetrics.side)
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
