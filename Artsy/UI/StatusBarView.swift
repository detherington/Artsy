import SwiftUI

struct StatusBarView: View {
    @ObservedObject var viewModel: CanvasViewModel

    var body: some View {
        HStack(spacing: 16) {
            Text("Tool: \(viewModel.currentTool.rawValue)")
                .font(.system(size: 11))

            if viewModel.currentTool == .selection {
                Text("(\(viewModel.selectionMode.rawValue))")
                    .font(.system(size: 11))
            }

            if viewModel.currentTool == .brush || viewModel.currentTool == .eraser {
                Text("Brush: \(viewModel.currentBrush.name)")
                    .font(.system(size: 11))

                Text("Size: \(Int(viewModel.brushSize))px")
                    .font(.system(size: 11, design: .monospaced))
            }

            Text("Zoom: \(Int(viewModel.transform.scale * 100))%")
                .font(.system(size: 11, design: .monospaced))

            if let path = viewModel.selectionPath {
                let bounds = path.boundingBox
                Text("Selection: \(Int(bounds.width))×\(Int(bounds.height))")
                    .font(.system(size: 11, design: .monospaced))
            }

            if let layerStack = viewModel.layerStack,
               let layer = layerStack.activeLayer {
                Text("Layer: \(layer.name)")
                    .font(.system(size: 11))
            }

            Spacer()

            Text("Canvas: \(Int(viewModel.canvasSize.width))×\(Int(viewModel.canvasSize.height))")
                .font(.system(size: 11, design: .monospaced))

            if !viewModel.isRightPanelVisible {
                Button(action: { viewModel.toggleRightPanel() }) {
                    Image(systemName: "sidebar.trailing")
                        .font(.system(size: 11))
                }
                .buttonStyle(.plain)
                .foregroundColor(.accentColor)
                .help("Show panel (Tab)")
            }
        }
        .foregroundColor(.gray)
        .padding(.horizontal, 12)
        .padding(.vertical, 4)
        .frame(height: 24)
        .background(Color(nsColor: NSColor(white: 0.12, alpha: 1.0)))
    }
}
