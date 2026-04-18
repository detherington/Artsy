import SwiftUI

/// Thin vertical icon bar shown when the right panel is in condensed mode.
/// Each icon opens a popover with the corresponding section's full content.
struct CondensedPanelView: View {
    @ObservedObject var viewModel: CanvasViewModel
    @StateObject private var aiManager = AIResultsManager()
    @StateObject private var unsplashManager = UnsplashManager()

    @State private var showBrushPopover = false
    @State private var showLayersPopover = false
    @State private var showAIPopover = false
    @State private var showUnsplashPopover = false

    var body: some View {
        VStack(spacing: 4) {
            // Expand back to full
            Button(action: { viewModel.toggleRightPanelMode() }) {
                Image(systemName: "sidebar.right")
                    .font(.system(size: 14))
                    .frame(width: 32, height: 32)
                    .foregroundColor(Color(white: 0.7))
                    .background(RoundedRectangle(cornerRadius: 6).fill(Color.clear))
            }
            .buttonStyle(.plain)
            .help("Expand panel")

            Divider().padding(.vertical, 2)

            // Brush / Shape (tool-aware icon)
            CondensedSectionButton(
                icon: brushIcon,
                tooltip: brushTooltip,
                isActive: showBrushPopover,
                action: { showBrushPopover.toggle() }
            )
            .popover(isPresented: $showBrushPopover, arrowEdge: .trailing) {
                ScrollView {
                    BrushSettingsView(viewModel: viewModel)
                        .frame(width: 260)
                        .padding(.vertical, 8)
                }
                .frame(width: 260, height: 320)
            }

            // Layers
            CondensedSectionButton(
                icon: "square.stack.3d.up",
                tooltip: "Layers",
                isActive: showLayersPopover,
                badgeValue: viewModel.layerStack?.layers.count,
                action: { showLayersPopover.toggle() }
            )
            .popover(isPresented: $showLayersPopover, arrowEdge: .trailing) {
                if let layerStack = viewModel.layerStack {
                    ScrollView {
                        LayerPanelView(viewModel: viewModel, layerStack: layerStack)
                            .frame(width: 260)
                            .padding(.vertical, 8)
                    }
                    .frame(width: 260, height: 400)
                }
            }

            // AI Generate
            CondensedSectionButton(
                icon: "sparkles",
                tooltip: "AI Generate",
                isActive: showAIPopover,
                action: { showAIPopover.toggle() }
            )
            .popover(isPresented: $showAIPopover, arrowEdge: .trailing) {
                ScrollView {
                    AIPanelView(viewModel: viewModel, aiManager: aiManager)
                        .frame(width: 300)
                        .padding(.vertical, 8)
                }
                .frame(width: 300, height: 600)
            }

            // Stock Images (Unsplash)
            CondensedSectionButton(
                icon: "photo.stack",
                tooltip: "Stock Images",
                isActive: showUnsplashPopover,
                action: { showUnsplashPopover.toggle() }
            )
            .popover(isPresented: $showUnsplashPopover, arrowEdge: .trailing) {
                ScrollView {
                    UnsplashPanelView(manager: unsplashManager)
                        .frame(width: 300)
                        .padding(.vertical, 8)
                }
                .frame(width: 300, height: 600)
            }

            Spacer()

            // Hide panel entirely
            Button(action: { viewModel.toggleRightPanel() }) {
                Image(systemName: "sidebar.trailing")
                    .font(.system(size: 12))
                    .frame(width: 32, height: 28)
                    .foregroundColor(Color(white: 0.55))
            }
            .buttonStyle(.plain)
            .help("Hide panel (Tab)")
        }
        .padding(.vertical, 8)
        .padding(.horizontal, 6)
        .background(Color(nsColor: NSColor(white: 0.13, alpha: 1.0)))
    }

    private var brushIcon: String {
        switch viewModel.currentTool {
        case .shape: return "square.on.circle"
        case .eraser: return "eraser"
        case .selection: return "rectangle.dashed"
        default: return "paintbrush.pointed"
        }
    }

    private var brushTooltip: String {
        switch viewModel.currentTool {
        case .shape: return "Shape Settings"
        case .eraser: return "Eraser Settings"
        case .selection: return "Selection Settings"
        default: return "Brush Settings"
        }
    }
}

struct CondensedSectionButton: View {
    let icon: String
    let tooltip: String
    let isActive: Bool
    var badgeValue: Int? = nil
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            ZStack(alignment: .topTrailing) {
                Image(systemName: icon)
                    .font(.system(size: 14))
                    .frame(width: 32, height: 32)
                    .foregroundColor(isActive ? .white : Color(white: 0.75))
                    .background(
                        RoundedRectangle(cornerRadius: 6)
                            .fill(isActive ? Color.accentColor.opacity(0.3) : Color.clear)
                    )

                if let badge = badgeValue, badge > 0 {
                    Text("\(badge)")
                        .font(.system(size: 8, weight: .bold, design: .monospaced))
                        .foregroundColor(.white)
                        .frame(minWidth: 12, minHeight: 12)
                        .padding(.horizontal, 2)
                        .background(Capsule().fill(Color.accentColor))
                        .offset(x: 3, y: -2)
                }
            }
        }
        .buttonStyle(.plain)
        .help(tooltip)
    }
}
