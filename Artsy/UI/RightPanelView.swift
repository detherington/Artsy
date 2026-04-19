import SwiftUI

struct RightPanelView: View {
    @ObservedObject var viewModel: CanvasViewModel
    @StateObject private var aiManager = AIResultsManager()
    @StateObject private var unsplashManager = UnsplashManager()

    // Section expansion state
    @State private var brushExpanded = true
    @State private var symmetryExpanded = false
    @State private var layersExpanded = true
    @State private var aiExpanded = false
    @State private var unsplashExpanded = false

    var body: some View {
        if viewModel.rightPanelMode == .condensed {
            CondensedPanelView(viewModel: viewModel)
        } else {
            fullPanelBody
        }
    }

    private var fullPanelBody: some View {
        VStack(spacing: 0) {
            // Panel header — title + mode controls
            HStack(spacing: 4) {
                Text(panelTitle)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(Color(white: 0.85))
                    .textCase(.uppercase)
                    .tracking(0.5)
                Spacer()

                Button(action: { viewModel.toggleRightPanelMode() }) {
                    Image(systemName: "sidebar.squares.right")
                        .font(.system(size: 12))
                        .foregroundColor(Color(white: 0.55))
                        .frame(width: 24, height: 20)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Condense panel to icon bar")

                Button(action: { viewModel.toggleRightPanel() }) {
                    Image(systemName: "sidebar.trailing")
                        .font(.system(size: 12))
                        .foregroundColor(Color(white: 0.55))
                        .frame(width: 24, height: 20)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Hide panel (Tab)")
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)

            Divider()

            // Scrollable stack of collapsible sections
            ScrollView {
                VStack(spacing: 0) {
                    DisclosureSection(
                        title: sectionTitle,
                        isExpanded: $brushExpanded,
                        iconName: viewModel.currentTool == .shape ? "square.on.circle" : "paintbrush.pointed"
                    ) {
                        BrushSettingsView(viewModel: viewModel)
                    }

                    Divider().opacity(0.35)

                    DisclosureSection(
                        title: "Symmetry",
                        isExpanded: $symmetryExpanded,
                        iconName: "circle.grid.cross",
                        trailing: AnyView(
                            Text(viewModel.symmetryMode.isOn ? viewModel.symmetryMode.displayName : "Off")
                                .font(.system(size: 10, design: .monospaced))
                                .foregroundColor(viewModel.symmetryMode.isOn
                                    ? .accentColor
                                    : Color(white: 0.55))
                        )
                    ) {
                        SymmetryControlView(viewModel: viewModel)
                    }

                    Divider().opacity(0.35)

                    if let layerStack = viewModel.layerStack {
                        DisclosureSection(
                            title: "Layers",
                            isExpanded: $layersExpanded,
                            iconName: "square.stack.3d.up",
                            trailing: AnyView(
                                Text("\(layerStack.layers.count)")
                                    .font(.system(size: 10, design: .monospaced))
                                    .foregroundColor(Color(white: 0.55))
                            )
                        ) {
                            LayerPanelView(viewModel: viewModel, layerStack: layerStack)
                        }

                        Divider().opacity(0.35)
                    }

                    DisclosureSection(
                        title: "AI Generate",
                        isExpanded: $aiExpanded,
                        iconName: "sparkles"
                    ) {
                        AIPanelView(viewModel: viewModel, aiManager: aiManager)
                    }

                    Divider().opacity(0.35)

                    DisclosureSection(
                        title: "Stock Images",
                        isExpanded: $unsplashExpanded,
                        iconName: "photo.stack"
                    ) {
                        UnsplashPanelView(manager: unsplashManager)
                    }

                    Spacer(minLength: 0)
                }
            }
        }
        .background(Color(nsColor: NSColor(white: 0.13, alpha: 1.0)))
    }

    private var panelTitle: String {
        "Inspector"
    }

    private var sectionTitle: String {
        switch viewModel.currentTool {
        case .shape: return "Shape"
        case .eraser: return "Eraser"
        case .selection: return "Selection"
        default: return "Brush"
        }
    }
}

// MARK: - Disclosure Section

struct DisclosureSection<Content: View>: View {
    let title: String
    @Binding var isExpanded: Bool
    let iconName: String?
    let trailing: AnyView?
    @ViewBuilder let content: () -> Content

    init(
        title: String,
        isExpanded: Binding<Bool>,
        iconName: String? = nil,
        trailing: AnyView? = nil,
        @ViewBuilder content: @escaping () -> Content
    ) {
        self.title = title
        self._isExpanded = isExpanded
        self.iconName = iconName
        self.trailing = trailing
        self.content = content
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Section header
            Button(action: {
                withAnimation(.easeInOut(duration: 0.18)) {
                    isExpanded.toggle()
                }
            }) {
                HStack(spacing: 8) {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundColor(Color(white: 0.55))
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                        .frame(width: 10)

                    if let iconName = iconName {
                        Image(systemName: iconName)
                            .font(.system(size: 11))
                            .foregroundColor(Color(white: 0.7))
                            .frame(width: 14)
                    }

                    Text(title)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(Color(white: 0.9))

                    Spacer()

                    if let trailing = trailing {
                        trailing
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 9)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            // Section content
            if isExpanded {
                content()
                    .padding(.bottom, 4)
            }
        }
    }
}
