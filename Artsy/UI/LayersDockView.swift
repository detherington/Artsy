import SwiftUI
import ArtsyEngine

/// Layers beside the canvas on a wide window: the same panel as the pop-up, with a
/// title and a way to put it back in the bar.
struct LayersDockView: View {
    @ObservedObject var viewModel: CanvasViewModel
    let renderer: CanvasRenderer?

    var body: some View {
        VStack(spacing: 0) {
            PanelHeader("Layers") {
                ChromeButton(systemImage: "rectangle.righthalf.inset.filled.arrow.right", help: "Undock layers") {
                    viewModel.isLayersDocked = false
                }
            }
            Divider().overlay(Chrome.hairline)
            if let layerStack = viewModel.layerStack {
                LayersPanelContent(viewModel: viewModel, layerStack: layerStack, renderer: renderer)
            }
        }
        .frame(width: Chrome.dockWidth)
        .frame(maxHeight: .infinity)
        .background(Chrome.panel)
    }
}

/// The layers as a pop-up from the bar, for a window too narrow for the dock.
struct LayersPanelView: View {
    @ObservedObject var viewModel: CanvasViewModel
    let renderer: CanvasRenderer?
    let dockAvailable: Bool

    var body: some View {
        VStack(spacing: 0) {
            PanelHeader("Layers") {
                if dockAvailable {
                    ChromeButton(systemImage: "rectangle.righthalf.inset.filled", help: "Dock layers beside the canvas") {
                        viewModel.isLayersDocked = true
                    }
                }
            }
            Divider().overlay(Chrome.hairline)
            if let layerStack = viewModel.layerStack {
                LayersPanelContent(viewModel: viewModel, layerStack: layerStack, renderer: renderer)
            }
        }
        .frame(width: Chrome.panelWidth, height: 520)
        .background(Chrome.panel)
    }
}
