import SwiftUI
import ArtsyEngine

/// The Fill tool's panel, over the canvas's top-right corner while the tool is in use (as
/// the lettering panel is for the Letter tool): how near a colour has to be to fill, what
/// the fill reads to find its region, the gaps it closes in the lines and how far it
/// spreads under them.
struct FillPanel: View {
    @ObservedObject var viewModel: CanvasViewModel

    static let width: CGFloat = 300

    var body: some View {
        if viewModel.currentTool == .fill, !viewModel.isChromeHidden, !viewModel.isEditingPerspective {
            panel
        }
    }

    private var panel: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("fill")
                .font(Chrome.futura(15, bold: true))
                .foregroundColor(Chrome.text)
                .padding(.horizontal, 16)
            HStack(spacing: 4) {
                ForEach(FillSource.allCases) { source in
                    SquareChoice(text: source.label, isSelected: viewModel.fillSource == source, height: 30,
                                 font: Chrome.labelFont, help: source.help) {
                        viewModel.fillSource = source
                    }
                }
            }
            .padding(.horizontal, 16)
            if viewModel.fillSource == .reference, let stack = viewModel.layerStack {
                ReferenceNote(layerStack: stack)
                    .padding(.horizontal, 16)
            }
            PanelSlider("Tolerance", value: Binding(get: { Float(viewModel.fillTolerance) },
                                                    set: { viewModel.fillTolerance = Int($0.rounded()) }),
                        range: 0...100) { "\(Int($0.rounded()))" }
            PanelSlider("Gaps", value: Binding(get: { Float(viewModel.fillCloseGaps) },
                                               set: { viewModel.fillCloseGaps = Int($0.rounded()) }),
                        range: 0...10) { "\(Int($0.rounded())) px" }
            PanelSlider("Spread", value: Binding(get: { Float(viewModel.fillSpread) },
                                                 set: { viewModel.fillSpread = Int($0.rounded()) }),
                        range: 0...8) { "\(Int($0.rounded())) px" }
        }
        .padding(.vertical, 14)
        .frame(width: Self.width)
        .background(Chrome.panel)
        .overlay(Rectangle().strokeBorder(Chrome.hairline))
    }
}

/// Said under the choice of the reference when no layer is marked as it.
private struct ReferenceNote: View {
    @ObservedObject var layerStack: LayerStack

    var body: some View {
        if let reference = layerStack.layers.first(where: { $0.isReference }) {
            note("Reads \(reference.name).")
        } else {
            note("No layer is the reference yet: mark the inks in the layers panel. Until then the fill reads its own layer.")
        }
    }

    private func note(_ text: String) -> some View {
        Text(text)
            .font(Chrome.labelFont)
            .foregroundColor(Chrome.secondaryText)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.top, 4)
    }
}

extension FillSource {
    var label: String {
        switch self {
        case .layer: return "this layer"
        case .all: return "all layers"
        case .reference: return "reference"
        }
    }

    var help: String {
        switch self {
        case .layer: return "Fill where this layer's colour runs"
        case .all: return "Fill where the picture's colour runs, every visible layer as one"
        case .reference: return "Fill inside the lines of the reference layer"
        }
    }
}
