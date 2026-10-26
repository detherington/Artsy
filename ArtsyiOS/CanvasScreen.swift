import SwiftUI
import UIKit
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
            let width = geometry.size.width
            let hidden = viewModel.isChromeHidden
            let wide = width >= Chrome.dockMinimumWindowWidth
            let phone = width < Chrome.phoneWidth
            let dockShown = !hidden && viewModel.isLayersDocked && wide
            VStack(spacing: 0) {
                HStack(spacing: 0) {
                    if !hidden && !phone {
                        ToolRailView(viewModel: viewModel, actions: session.actions)
                    }
                    ZStack(alignment: .bottomLeading) {
                        canvas
                        if hidden {
                            ChromePillView(viewModel: viewModel, previews: session.previews, actions: session.actions)
                                .padding(12)
                        }
                        if !hidden && phone {
                            // The rail's tools over the canvas, where a phone has no room beside it
                            ToolStripView(viewModel: viewModel, actions: session.actions)
                                .padding(8)
                                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
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
            .onAppear {
                layout(for: width)
                let kind = phone ? "phone" : width < Chrome.compactBarWidth ? "compact" : wide ? "wide" : "regular"
                DiagnosticsLog.shared.note(.app, "screen \(Int(width))×\(Int(geometry.size.height)) pt at \(Int(UIScreen.main.scale))x, \(kind) layout")
            }
            .onChange(of: width) { _, width in layout(for: width) }
        }
        .background(Chrome.background.ignoresSafeArea())
        .animation(.easeInOut(duration: 0.2), value: viewModel.isChromeHidden)
    }

    /// The breakpoints, from the width: the dock beside the canvas, the compact bar, the phone.
    private func layout(for width: CGFloat) {
        let wide = width >= Chrome.dockMinimumWindowWidth
        let compact = width < Chrome.compactBarWidth
        let phone = width < Chrome.phoneWidth
        if chrome.isWide != wide { chrome.isWide = wide }
        if chrome.isCompact != compact { chrome.isCompact = compact }
        if chrome.isPhone != phone { chrome.isPhone = phone }
    }

    private var canvas: some View {
        CanvasHost(view: session.paintingView)
            .ignoresSafeArea(edges: .top)
    }
}
