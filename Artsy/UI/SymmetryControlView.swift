import SwiftUI

/// Compact inspector control for picking a symmetry mode.
struct SymmetryControlView: View {
    @ObservedObject var viewModel: CanvasViewModel

    private static let radialChoices: [Int] = [3, 4, 6, 8, 12]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Basic modes — icon grid
            HStack(spacing: 6) {
                modeButton("Off",        systemImage: "nosign",           mode: .off)
                modeButton("Horizontal", systemImage: "align.vertical.center.fill", mode: .horizontal)
                modeButton("Vertical",   systemImage: "align.horizontal.center.fill", mode: .vertical)
                modeButton("Quad",       systemImage: "square.grid.2x2.fill", mode: .quad)
            }

            // Radial row with an N picker
            HStack(spacing: 6) {
                Text("Radial")
                    .font(.system(size: 11))
                    .foregroundColor(.gray)
                ForEach(Self.radialChoices, id: \.self) { n in
                    Button(action: { viewModel.symmetryMode = .radial(n) }) {
                        Text("\(n)")
                            .font(.system(size: 11, weight: .medium, design: .monospaced))
                            .frame(width: 24, height: 22)
                            .background(
                                isRadial(n)
                                    ? Color.accentColor.opacity(0.35)
                                    : Color(white: 0.22)
                            )
                            .cornerRadius(4)
                    }
                    .buttonStyle(.plain)
                    .foregroundColor(isRadial(n) ? .white : Color(white: 0.7))
                    .help("\(n)-fold radial symmetry")
                }
            }

            Text("Mirrors strokes around the canvas center. Works with any brush.")
                .font(.system(size: 10))
                .foregroundColor(.gray.opacity(0.75))
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 6)
    }

    private func isRadial(_ n: Int) -> Bool {
        if case .radial(let current) = viewModel.symmetryMode { return current == n }
        return false
    }

    private func modeButton(_ label: String, systemImage: String, mode: SymmetryMode) -> some View {
        let selected = viewModel.symmetryMode == mode
        return Button(action: { viewModel.symmetryMode = mode }) {
            VStack(spacing: 2) {
                Image(systemName: systemImage)
                    .font(.system(size: 14))
                Text(label)
                    .font(.system(size: 9))
            }
            .frame(maxWidth: .infinity)
            .frame(height: 36)
            .background(selected ? Color.accentColor.opacity(0.35) : Color(white: 0.22))
            .cornerRadius(4)
        }
        .buttonStyle(.plain)
        .foregroundColor(selected ? .white : Color(white: 0.7))
        .help("\(label) symmetry")
    }
}
