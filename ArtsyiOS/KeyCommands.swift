import UIKit
import ArtsyEngine

/// The keys an iPad with a keyboard answers to: the Mac's, as key commands on the canvas
/// screen, so the panels' key notes hold there too. Tool keys wait for a stroke to end,
/// as on the Mac, since the renderer reads the tool every frame.
enum KeyCommands {
    struct Entry {
        let id: String
        let title: String
        let input: String
        let modifiers: UIKeyModifierFlags
        /// Takes the key from the system: Tab, which otherwise moves keyboard focus.
        let overridesSystem: Bool
        let run: () -> Void

        init(_ id: String, _ title: String, _ input: String, _ modifiers: UIKeyModifierFlags = [], overridesSystem: Bool = false, run: @escaping () -> Void) {
            self.id = id
            self.title = title
            self.input = input
            self.modifiers = modifiers
            self.overridesSystem = overridesSystem
            self.run = run
        }
    }

    static func entries(for session: PaintingSession, app: @escaping (String) -> Void) -> [Entry] {
        let viewModel = session.viewModel
        let actions = session.actions
        /// A key that changes the tool, the brush or the colour: not under a stroke.
        func tool(_ id: String, _ title: String, _ key: String, _ change: @escaping (CanvasViewModel) -> Void) -> Entry {
            Entry(id, title, key) { [weak viewModel] in
                guard let viewModel, !viewModel.isDrawing else { return }
                change(viewModel)
            }
        }
        var list: [Entry] = [
            tool("brush", "Brush", "b") { $0.currentTool = .brush; $0.currentBrush = .hardRound },
            tool("eraser", "Eraser", "e") { $0.currentTool = .eraser; $0.currentBrush = .eraser },
            tool("fill", "Fill", "g") { $0.currentTool = .fill },
            tool("eyedropper", "Eyedropper", "i") { $0.currentTool = .eyedropper },
            tool("smaller", "Smaller brush", "[") { $0.brushSize = max(1, $0.brushSize - 2) },
            tool("larger", "Larger brush", "]") { $0.brushSize = min(500, $0.brushSize + 2) },
            tool("lessOpaque", "Less opaque", "{") { $0.brushOpacity = max(0.05, $0.brushOpacity - 0.05) },
            tool("moreOpaque", "More opaque", "}") { $0.brushOpacity = min(1, $0.brushOpacity + 0.05) },
            tool("resetColors", "Black on white", "d") { $0.resetColors() },
            tool("swapColors", "Swap the colours", "x") { $0.swapColors() },
        ]
        for number in 1...9 {
            list.append(tool("brush\(number)", "Brush \(number)", "\(number)") { viewModel in
                // The first nine brushes of the library, as the brush panel numbers them
                let library = BrushLibrary.shared.all
                guard number - 1 < library.count else { return }
                let brush = library[number - 1]
                viewModel.currentBrush = brush
                viewModel.currentTool = brush.id == BrushDescriptor.eraser.id ? .eraser : .brush
            })
        }
        list += [
            Entry("chrome", "Hide or show the interface", "\t", overridesSystem: true) { [weak viewModel] in viewModel?.toggleChrome() },
            Entry("undo", "Undo", "z", .command, run: actions.undo),
            Entry("redo", "Redo", "z", [.command, .shift], run: actions.redo),
            Entry("zoomToFit", "Zoom to fit", "0", .command, run: actions.zoomToFit),
            Entry("actualSize", "Actual size", "1", .command, run: actions.actualSize),
            Entry("zoomIn", "Zoom in", "=", .command) { [weak session] in session?.zoom(by: 1.5) },
            Entry("zoomOut", "Zoom out", "-", .command) { [weak session] in session?.zoom(by: 0.667) },
            Entry("rotateLeft", "Rotate left", "[", [.command, .alternate]) { actions.rotate(1) },
            Entry("rotateRight", "Rotate right", "]", [.command, .alternate]) { actions.rotate(-1) },
            Entry("resetRotation", "Reset rotation", "0", [.command, .alternate], run: actions.resetRotation),
            Entry("flip", "Flip view", "f", [.command, .alternate], run: actions.flip),
            Entry("grid", "Grid", "'", .command) { actions.changeGuides { $0.showsGrid.toggle() } },
            Entry("save", "Save now", "s", .command) { app("handleSave") },
            Entry("documents", "Documents", "o", .command) { app("handleOpen") },
            Entry("new", "New canvas", "n", .command) { app("showNewCanvasDialog") },
            Entry("exportPNG", "Export PNG", "e", .command) { app("handleExportPNG") },
            Entry("exportJPEG", "Export JPEG", "e", [.command, .shift]) { app("handleExportJPEG") },
            Entry("studio", "Brush Studio", "b", [.command, .shift]) { app("showBrushStudio") },
            Entry("settings", "Settings", ",", .command) { app("showSettings") },
            Entry("shortcuts", "Keyboard Shortcuts", "/", .command) { app("showShortcuts") },
        ]
        return list
    }
}
