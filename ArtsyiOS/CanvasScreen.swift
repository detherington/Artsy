import SwiftUI
import ArtsyEngine

/// The screen: the canvas with the Mac's chrome around it. The tool rail on the left,
/// the bar along the bottom, the Layers dock on the right when the screen is wide enough
/// and the user wants it there, and, with the chrome hidden, a pill in the corner that
/// keeps the brush and the colour within reach. The same views as the Mac's `MainLayout`,
/// laid out in SwiftUI.
struct CanvasScreen: View {
    let session: PaintingSession
    @ObservedObject var viewModel: CanvasViewModel
    @ObservedObject var chrome: ChromeState

    init(session: PaintingSession) {
        self.session = session
        self.viewModel = session.viewModel
        self.chrome = session.chrome
    }

    var body: some View {
        GeometryReader { geometry in
            let hidden = viewModel.isChromeHidden
            let wide = geometry.size.width >= Chrome.dockMinimumWindowWidth
            let dockShown = !hidden && viewModel.isLayersDocked && wide
            VStack(spacing: 0) {
                HStack(spacing: 0) {
                    if !hidden {
                        ToolRailView(viewModel: viewModel, actions: session.actions)
                    }
                    ZStack(alignment: .bottomLeading) {
                        canvas
                        if hidden {
                            ChromePillView(viewModel: viewModel, previews: session.previews, actions: session.actions)
                                .padding(12)
                        }
                        ZoomHUDView(viewModel: viewModel)
                            .frame(maxWidth: .infinity)
                            .padding(.bottom, 12)
                    }
                    if dockShown {
                        LayersDockView(viewModel: viewModel, renderer: session.renderer)
                            .frame(width: Chrome.dockWidth)
                    }
                }
                if !hidden {
                    BottomBarView(viewModel: viewModel, chrome: chrome, previews: session.previews, actions: session.actions)
                }
            }
            .onAppear { chrome.isWide = wide }
            .onChange(of: wide) { _, wide in chrome.isWide = wide }
        }
        .background(Chrome.background.ignoresSafeArea())
        .animation(.easeInOut(duration: 0.2), value: viewModel.isChromeHidden)
    }

    @ViewBuilder
    private var canvas: some View {
        if let view = session.paintingView {
            CanvasHost(view: view)
                .ignoresSafeArea(edges: .top)
        } else {
            Text(session.failure ?? "The engine could not start")
                .foregroundColor(Chrome.text)
                .padding()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}
