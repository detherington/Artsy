import SwiftUI
import ArtsyEngine

/// The drawing guide's panel, over the canvas's top-right corner while its handles are
/// being moved (as the lettering panel is for the Letter tool): for perspective, how many
/// points and the horizon levelled; for the ruler, its angle and straightening; for the
/// ellipse, its degree, straightening and every size. Each has the snap, remove, and done.
/// Speed or focus lines being laid out get theirs here too: their kind, how many, how wide,
/// how varied, shuffle, and make or cancel. The handles themselves are dragged on the canvas.
struct DrawingGuidePanel: View {
    @ObservedObject var viewModel: CanvasViewModel
    let actions: ChromeActions
    @State private var failure: String?

    static let width: CGFloat = 300

    var body: some View {
        switch viewModel.editingGuide {
        case .perspective?:
            if let perspective = viewModel.guides.perspective {
                frame(title: "perspective") { perspectiveControls(perspective) }
            }
        case .ruler?:
            if let ruler = viewModel.guides.ruler {
                frame(title: "ruler") { rulerControls(ruler) }
            }
        case .ellipse?:
            if let ellipse = viewModel.guides.ellipse {
                frame(title: "ellipse") { ellipseControls(ellipse) }
            }
        case .lines?:
            if let lines = viewModel.comicLines {
                frame(title: lines.kind == .focus ? "focus lines" : "speed lines", close: "cancel",
                      closeHelp: "Let the lines go, unmade (Escape)") { linesControls(lines) }
            }
        case nil:
            EmptyView()
        }
    }

    private func frame<Content: View>(title: String, close: String = "done", closeHelp: String = "Stop moving it (Return)",
                                      @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(title)
                    .font(Chrome.futura(15, bold: true))
                    .foregroundColor(Chrome.text)
                Spacer()
                Button(close) { viewModel.endGuideEditing() }
                    .buttonStyle(.plain)
                    .font(Chrome.futura(14, bold: true))
                    .foregroundColor(Chrome.accent)
                    .frame(height: 32)
                    .help(closeHelp)
            }
            .padding(.horizontal, 16)
            content()
        }
        .padding(.vertical, 12)
        .frame(width: Self.width)
        .background(Chrome.panel)
        .overlay(Rectangle().strokeBorder(Chrome.hairline))
    }

    private func choice(_ text: String, selected: Bool = false, help: String, action: @escaping () -> Void) -> some View {
        SquareChoice(text: text, isSelected: selected, height: 30, font: Chrome.labelFont, help: help, action: action)
    }

    private func row<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        HStack(spacing: 4) { content() }
            .padding(.horizontal, 16)
    }

    private func hint(_ text: String) -> some View {
        Text(text)
            .font(Chrome.labelFont)
            .foregroundColor(Chrome.secondaryText)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 16)
            .padding(.top, 2)
    }

    private func reading(_ label: String, _ value: String) -> some View {
        HStack(spacing: 6) {
            Text(label)
                .font(Chrome.labelFont)
                .foregroundColor(Chrome.secondaryText)
            Text(value)
                .font(Chrome.valueFont)
                .foregroundColor(Chrome.text)
                .monospacedDigit()
        }
        .frame(minWidth: 90, alignment: .leading)
    }

    // MARK: - Perspective

    @ViewBuilder
    private func perspectiveControls(_ perspective: PerspectiveGuide) -> some View {
        row {
            ForEach(1...3, id: \.self) { count in
                choice("\(count) point", selected: perspective.points.count == count, help: Self.help(points: count)) {
                    actions.setPerspective(count)
                }
            }
        }
        row {
            choice("snap", selected: perspective.snaps, help: "Strokes run along the perspective's lines") {
                actions.changeGuides { $0.perspective?.snaps.toggle() }
            }
            if perspective.points.count >= 2 {
                choice("level", help: "The second point level with the first, so the horizon is flat") {
                    actions.changeGuides { $0.perspective?.levelHorizon() }
                }
            }
            choice("remove", help: "Take the perspective away") { viewModel.removeGuide(.perspective) }
        }
        hint(perspective.points.count >= 2
             ? "Drag a point to move it, or the square to move the horizon."
             : "Drag the point to move it and the horizon.")
    }

    private static func help(points: Int) -> String {
        switch points {
        case 1: return "One point: a road or a room seen straight on"
        case 2: return "Two points: a building seen from its corner"
        default: return "Three points: looking up or down at a tall building"
        }
    }

    // MARK: - Ruler

    @ViewBuilder
    private func rulerControls(_ ruler: RulerGuide) -> some View {
        row {
            reading("angle", "\(Int(ruler.angle.rounded()) % 180)°")
            choice("straighten", help: "Turn it to the nearest 15°") {
                actions.changeGuides { $0.ruler?.straighten() }
            }
        }
        row {
            choice("snap", selected: ruler.snaps, help: "A stroke laid against the ruler runs along it") {
                actions.changeGuides { $0.ruler?.snaps.toggle() }
            }
            choice("remove", help: "Take the ruler away") { viewModel.removeGuide(.ruler) }
        }
        hint("Drag an end to turn or lengthen it, or the square to move it. A stroke started on it runs along it.")
    }

    // MARK: - Ellipse

    @ViewBuilder
    private func ellipseControls(_ ellipse: EllipseGuide) -> some View {
        row {
            reading("degree", "\(Int(ellipse.degree.rounded()))°")
            choice("−", help: "Flatter, by 5°") { actions.changeGuides { $0.ellipse?.stepDegree(by: -1) } }
            choice("+", help: "Rounder, by 5° (90° is a circle)") { actions.changeGuides { $0.ellipse?.stepDegree(by: 1) } }
        }
        row {
            choice("straighten", help: "Turn its axes to the nearest 15°") {
                actions.changeGuides { $0.ellipse?.straighten() }
            }
            choice("every size", selected: ellipse.everySize,
                   help: "A stroke anywhere runs round the ellipse of this shape through where it starts") {
                actions.changeGuides { $0.ellipse?.everySize.toggle() }
            }
        }
        row {
            choice("snap", selected: ellipse.snaps, help: "A stroke laid against the ellipse runs round it") {
                actions.changeGuides { $0.ellipse?.snaps.toggle() }
            }
            choice("remove", help: "Take the ellipse away") { viewModel.removeGuide(.ellipse) }
        }
        hint("Drag the square to move it, the ring on its first axis to turn it and set its length, the other ring to set its width.")
    }

    // MARK: - Speed and focus lines

    private func changeLines(_ change: (inout ComicLines) -> Void) {
        guard var lines = viewModel.comicLines else { return }
        change(&lines)
        viewModel.comicLines = lines
    }

    @ViewBuilder
    private func linesControls(_ lines: ComicLines) -> some View {
        row {
            ForEach(ComicLines.Kind.allCases) { kind in
                choice(kind.rawValue, selected: lines.kind == kind,
                       help: kind == .focus ? "Lines running in to the subject, for a moment's punch" : "Lines side by side, for motion") {
                    actions.startLines(kind)
                }
            }
        }
        row {
            reading("lines", "\(lines.count)")
            choice("−", help: "Fewer lines") { changeLines { $0.stepCount(by: -1) } }
            choice("+", help: "More lines") { changeLines { $0.stepCount(by: 1) } }
        }
        row {
            reading("width", "\(Int(lines.width.rounded())) px")
            choice("−", help: "Thinner, by a fifth") { changeLines { $0.stepWidth(by: -1) } }
            choice("+", help: "Wider, by a quarter") { changeLines { $0.stepWidth(by: 1) } }
        }
        row {
            reading("variety", "\(Int((lines.variety * 100).rounded()))%")
            choice("−", help: "Lines more alike") { changeLines { $0.stepVariety(by: -1) } }
            choice("+", help: "Lines more varied in length, width and spacing") { changeLines { $0.stepVariety(by: 1) } }
        }
        row {
            choice("shuffle", help: "The same settings, dealt again") { changeLines { $0.shuffle() } }
            if lines.kind == .speed {
                choice("keep clear", selected: lines.keepsClear, help: "Stop at the clear area, so the subject stays clear") {
                    changeLines { $0.keepsClear.toggle() }
                }
            }
        }
        Button(action: make) {
            Text("make")
                .font(Chrome.futura(14, bold: true))
                .foregroundColor(.white)
                .frame(maxWidth: .infinity, minHeight: 40)
                .background(Rectangle().fill(Chrome.accent))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Draw them onto a new layer in the current colour (Return)")
        .padding(.horizontal, 16)
        .padding(.top, 4)
        if let failure {
            hint(failure).foregroundColor(Chrome.accent)
        }
        hint(lines.kind == .focus
             ? "Drag the square to move the clear area, its rings to turn and size it. The lines run in to its edge."
             : "Drag the square to move the clear area, its rings to turn and size it. The lines run along it.")
    }

    private func make() {
        guard let renderer = actions.renderer() else { return }
        ChromeActions.commitPendingEdits()
        do {
            try viewModel.makeLines(renderer: renderer)
            failure = nil
        } catch {
            failure = error.localizedDescription
        }
    }
}

