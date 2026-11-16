import SwiftUI
import ArtsyEngine

/// The perspective panel, over the canvas's top-right corner while the vanishing points
/// are being moved (as the lettering panel is for the Letter tool): how many points,
/// whether strokes snap to them, the horizon levelled, the perspective removed, and done.
/// The points themselves are dragged on the canvas.
struct PerspectivePanel: View {
    @ObservedObject var viewModel: CanvasViewModel
    let actions: ChromeActions

    static let width: CGFloat = 300

    var body: some View {
        if viewModel.isEditingPerspective, let perspective = viewModel.guides.perspective {
            panel(perspective)
        }
    }

    private func panel(_ perspective: PerspectiveGuide) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("perspective")
                    .font(Chrome.futura(15, bold: true))
                    .foregroundColor(Chrome.text)
                Spacer()
                Button("done") { viewModel.endPerspectiveEditing() }
                    .buttonStyle(.plain)
                    .font(Chrome.futura(14, bold: true))
                    .foregroundColor(Chrome.accent)
                    .frame(height: 32)
                    .help("Stop moving the points (Return)")
            }
            .padding(.horizontal, 16)
            HStack(spacing: 4) {
                ForEach(1...3, id: \.self) { count in
                    SquareChoice(text: "\(count) point", isSelected: perspective.points.count == count, height: 30,
                                 font: Chrome.labelFont, help: Self.help(points: count)) {
                        actions.setPerspective(count)
                    }
                }
            }
            .padding(.horizontal, 16)
            HStack(spacing: 4) {
                SquareChoice(text: "snap", isSelected: perspective.snaps, height: 30, font: Chrome.labelFont,
                             help: "Strokes run along the perspective's lines") {
                    actions.changeGuides { $0.perspective?.snaps.toggle() }
                }
                if perspective.points.count >= 2 {
                    SquareChoice(text: "level", isSelected: false, height: 30, font: Chrome.labelFont,
                                 help: "The second point level with the first, so the horizon is flat") {
                        actions.changeGuides { $0.perspective?.levelHorizon() }
                    }
                }
                SquareChoice(text: "remove", isSelected: false, height: 30, font: Chrome.labelFont,
                             help: "Take the perspective away") {
                    viewModel.removePerspective()
                }
            }
            .padding(.horizontal, 16)
            Text(perspective.points.count >= 2
                 ? "Drag a point to move it, or the square to move the horizon."
                 : "Drag the point to move it and the horizon.")
                .font(Chrome.labelFont)
                .foregroundColor(Chrome.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 16)
                .padding(.top, 2)
        }
        .padding(.vertical, 12)
        .frame(width: Self.width)
        .background(Chrome.panel)
        .overlay(Rectangle().strokeBorder(Chrome.hairline))
    }

    private static func help(points: Int) -> String {
        switch points {
        case 1: return "One point: a road or a room seen straight on"
        case 2: return "Two points: a building seen from its corner"
        default: return "Three points: looking up or down at a tall building"
        }
    }
}
