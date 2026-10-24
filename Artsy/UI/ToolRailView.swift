import SwiftUI

/// The tools, down the left of the window, each a button a pen can hit; a second tap
/// on a tool with modes (select, shape) opens them. Undo and redo are at the bottom:
/// the most-pressed buttons in any painting app, and a pen has no ⌘Z.
struct ToolRailView: View {
    @ObservedObject var viewModel: CanvasViewModel
    let actions: ChromeActions
    @State private var modesFor: ToolType?

    /// Pan is a gesture (space, the middle button, two fingers), not a tool in the rail.
    static let tools: [ToolType] = [.brush, .eraser, .fill, .eyedropper, .selection, .shape, .transform]

    var body: some View {
        VStack(spacing: 2) {
            ForEach(Self.tools) { tool in
                ChromeButton(
                    systemImage: tool == .fill ? nil : tool.iconName,
                    image: tool == .fill ? "paintbucket" : nil,
                    isSelected: viewModel.currentTool == tool,
                    help: "\(tool.rawValue) (\(tool.shortcutKey))"
                ) {
                    select(tool)
                }
                .popover(isPresented: Binding(get: { modesFor == tool }, set: { if !$0 { modesFor = nil } }),
                         arrowEdge: .trailing) {
                    modes(for: tool)
                }
            }
            Spacer(minLength: 8)
            ChromeButton(systemImage: "arrow.uturn.backward", help: "Undo (⌘Z)", action: actions.undo)
            ChromeButton(systemImage: "arrow.uturn.forward", help: "Redo (⇧⌘Z)", action: actions.redo)
        }
        .padding(.vertical, 6)
        .frame(width: Chrome.railWidth)
        .frame(maxHeight: .infinity)
        .background(Chrome.background)
    }

    private func select(_ tool: ToolType) {
        if viewModel.currentTool == tool, tool == .selection || tool == .shape {
            modesFor = tool
            return
        }
        viewModel.currentTool = tool
        switch tool {
        case .brush:
            if viewModel.currentBrush.id == BrushDescriptor.eraser.id {
                viewModel.currentBrush = .hardRound
            }
        case .eraser:
            viewModel.currentBrush = .eraser
        default:
            break
        }
    }

    @ViewBuilder
    private func modes(for tool: ToolType) -> some View {
        HStack(spacing: 4) {
            if tool == .selection {
                ForEach(SelectionMode.allCases) { mode in
                    ChromeButton(systemImage: mode.iconName, label: mode.rawValue,
                                 isSelected: viewModel.selectionMode == mode, help: mode.rawValue) {
                        viewModel.selectionMode = mode
                        modesFor = nil
                    }
                }
            } else {
                ForEach(ShapeMode.allCases) { mode in
                    ChromeButton(systemImage: mode.iconName, label: mode.rawValue,
                                 isSelected: viewModel.currentShape == mode, help: mode.rawValue) {
                        viewModel.currentShape = mode
                        modesFor = nil
                    }
                }
            }
        }
        .padding(8)
    }
}

/// What the chrome asks of the window it is in: things that need the canvas view (its
/// size, its undo) or the app (files, the studio). Built by `MainLayout`.
struct ChromeActions {
    /// The window's renderer, for what a panel does to layers; nil when there is none.
    var renderer: () -> CanvasRenderer? = { nil }
    var undo: () -> Void = {}
    var redo: () -> Void = {}
    var zoomToFit: () -> Void = {}
    var actualSize: () -> Void = {}
    /// +1 turns counter-clockwise, −1 clockwise.
    var rotate: (CGFloat) -> Void = { _ in }
    var resetRotation: () -> Void = {}
    /// Fit the canvas to the window, upright and unflipped.
    var resetView: () -> Void = {}
    var flip: () -> Void = {}
    var changeGuides: ((inout CanvasGuides) -> Void) -> Void = { _ in }
    /// A guide through the middle of the view: horizontal if true.
    var addGuide: (Bool) -> Void = { _ in }
    /// An app-level action by its selector name, run after any pop-up has closed so it
    /// lands on the canvas window.
    var app: (String) -> Void = { name in
        DispatchQueue.main.async { NSApp.sendAction(Selector((name)), to: nil, from: nil) }
    }
}
