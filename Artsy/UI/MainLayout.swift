import AppKit
import Combine
import SwiftUI

/// The window's contents: the canvas with the chrome around it. The tool rail on the
/// left, the bar along the bottom, the Layers dock on the right when the window is wide
/// enough and the user wants it there, and, with the chrome hidden, a pill in the corner
/// that keeps the brush and the colour within reach.
final class MainLayout: NSView {
    let canvasView: CanvasView
    let viewModel: CanvasViewModel
    private let chrome: ChromeState
    private let rail: NSHostingView<ToolRailView>
    private let bar: NSHostingView<BottomBarView>
    private let dock: NSHostingView<LayersDockView>
    private let pill: NSHostingView<ChromePillView>
    private let zoomHUD: NSHostingView<ZoomHUDView>
    private let selectionOverlay = SelectionOverlayView()
    private var railWidth: NSLayoutConstraint!
    private var barHeight: NSLayoutConstraint!
    private var dockWidth: NSLayoutConstraint!
    private var chromeHidden = false
    private var layersDocked: Bool
    private var cancellables = Set<AnyCancellable>()
    /// Whether the Layers dock is showing; for tests.
    private(set) var isDockShown = false

    init(canvasView: CanvasView, viewModel: CanvasViewModel, previewRenderer: BrushPreview?) {
        self.canvasView = canvasView
        self.viewModel = viewModel
        let chrome = ChromeState()
        self.chrome = chrome
        let previews = BrushPreviewCache(renderer: previewRenderer)
        let actions = Self.actions(for: canvasView, viewModel: viewModel)
        rail = NSHostingView(rootView: ToolRailView(viewModel: viewModel, actions: actions))
        bar = NSHostingView(rootView: BottomBarView(viewModel: viewModel, chrome: chrome, previews: previews, actions: actions))
        dock = NSHostingView(rootView: LayersDockView(viewModel: viewModel, renderer: canvasView.renderer))
        pill = NSHostingView(rootView: ChromePillView(viewModel: viewModel, previews: previews, actions: actions))
        zoomHUD = NSHostingView(rootView: ZoomHUDView(viewModel: viewModel))
        layersDocked = viewModel.isLayersDocked
        super.init(frame: .zero)
        wantsLayer = true

        selectionOverlay.viewModel = viewModel
        selectionOverlay.wantsLayer = true
        for view in [rail, canvasView, selectionOverlay, dock, bar, pill, zoomHUD] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        rail.clipsToBounds = true
        dock.clipsToBounds = true
        bar.clipsToBounds = true
        // Until the first update says otherwise: the chrome up, the pill and the dock away
        pill.isHidden = true
        dock.isHidden = true

        railWidth = rail.widthAnchor.constraint(equalToConstant: Chrome.railWidth)
        barHeight = bar.heightAnchor.constraint(equalToConstant: Chrome.barHeight)
        dockWidth = dock.widthAnchor.constraint(equalToConstant: 0)
        NSLayoutConstraint.activate([
            rail.leadingAnchor.constraint(equalTo: leadingAnchor),
            rail.topAnchor.constraint(equalTo: topAnchor),
            rail.bottomAnchor.constraint(equalTo: bar.topAnchor),
            railWidth,

            dock.trailingAnchor.constraint(equalTo: trailingAnchor),
            dock.topAnchor.constraint(equalTo: topAnchor),
            dock.bottomAnchor.constraint(equalTo: bar.topAnchor),
            dockWidth,

            canvasView.leadingAnchor.constraint(equalTo: rail.trailingAnchor),
            canvasView.trailingAnchor.constraint(equalTo: dock.leadingAnchor),
            canvasView.topAnchor.constraint(equalTo: topAnchor),
            canvasView.bottomAnchor.constraint(equalTo: bar.topAnchor),

            selectionOverlay.leadingAnchor.constraint(equalTo: canvasView.leadingAnchor),
            selectionOverlay.trailingAnchor.constraint(equalTo: canvasView.trailingAnchor),
            selectionOverlay.topAnchor.constraint(equalTo: canvasView.topAnchor),
            selectionOverlay.bottomAnchor.constraint(equalTo: canvasView.bottomAnchor),

            bar.leadingAnchor.constraint(equalTo: leadingAnchor),
            bar.trailingAnchor.constraint(equalTo: trailingAnchor),
            bar.bottomAnchor.constraint(equalTo: bottomAnchor),
            barHeight,

            pill.leadingAnchor.constraint(equalTo: canvasView.leadingAnchor, constant: 12),
            pill.bottomAnchor.constraint(equalTo: canvasView.bottomAnchor, constant: -12),

            zoomHUD.centerXAnchor.constraint(equalTo: canvasView.centerXAnchor),
            zoomHUD.bottomAnchor.constraint(equalTo: canvasView.bottomAnchor, constant: -12),
        ])
        selectionOverlay.startAnimation()

        // Published values arrive before the property changes, so the new value is the
        // one delivered, not the one read back
        viewModel.$isChromeHidden
            .dropFirst()
            .sink { [weak self] hidden in
                self?.chromeHidden = hidden
                self?.updateChrome(animated: true)
            }
            .store(in: &cancellables)
        viewModel.$isLayersDocked
            .dropFirst()
            .sink { [weak self] docked in
                self?.layersDocked = docked
                self?.updateChrome(animated: true)
            }
            .store(in: &cancellables)
        updateChrome(animated: false)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    /// What the chrome asks of this window: the canvas's size and undo, the view model's
    /// view and guides. Weak, so the chrome keeps nothing alive.
    private static func actions(for canvasView: CanvasView, viewModel: CanvasViewModel) -> ChromeActions {
        var actions = ChromeActions()
        actions.renderer = { [weak canvasView] in canvasView?.renderer }
        actions.undo = { [weak canvasView] in canvasView?.performUndoAction() }
        actions.redo = { [weak canvasView] in canvasView?.performRedoAction() }
        actions.zoomToFit = { [weak canvasView, weak viewModel] in
            guard let canvasView else { return }
            viewModel?.zoomToFit(viewSize: canvasView.bounds.size)
        }
        actions.actualSize = { [weak viewModel] in viewModel?.actualSize() }
        actions.rotate = { [weak canvasView, weak viewModel] direction in
            guard let canvasView else { return }
            viewModel?.rotateView(direction: direction, viewSize: canvasView.bounds.size)
        }
        actions.resetRotation = { [weak canvasView, weak viewModel] in
            guard let canvasView else { return }
            viewModel?.resetRotation(viewSize: canvasView.bounds.size)
        }
        actions.flip = { [weak canvasView, weak viewModel] in
            guard let canvasView else { return }
            viewModel?.flipView(viewSize: canvasView.bounds.size)
        }
        actions.changeGuides = { [weak canvasView, weak viewModel] change in
            viewModel?.changeGuides(change)
            canvasView?.redrawOverlays()
        }
        actions.addGuide = { [weak canvasView, weak viewModel] horizontal in
            guard let canvasView else { return }
            viewModel?.addGuide(horizontal: horizontal, viewSize: canvasView.bounds.size)
            canvasView.redrawOverlays()
        }
        return actions
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        updateChrome(animated: false)
    }

    private func updateChrome(animated: Bool) {
        let wide = bounds.width >= Chrome.dockMinimumWindowWidth
        if chrome.isWide != wide { chrome.isWide = wide }
        let dockShown = !chromeHidden && layersDocked && wide
        let targets: [(NSLayoutConstraint, CGFloat)] = [
            (railWidth, chromeHidden ? 0 : Chrome.railWidth),
            (barHeight, chromeHidden ? 0 : Chrome.barHeight),
            (dockWidth, dockShown ? Chrome.dockWidth : 0),
        ]
        guard targets.contains(where: { $0.0.constant != $0.1 }) || rail.isHidden != chromeHidden || isDockShown != dockShown else { return }
        isDockShown = dockShown
        let apply = {
            for (constraint, constant) in targets { constraint.constant = constant }
            self.rail.isHidden = self.chromeHidden
            self.bar.isHidden = self.chromeHidden
            self.dock.isHidden = !dockShown
            self.pill.isHidden = !self.chromeHidden
        }
        // An animation needs a window on screen; without one (tests) the frames land at once
        if animated, window?.isVisible == true {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.2
                context.allowsImplicitAnimation = true
                apply()
                self.layoutSubtreeIfNeeded()
            }
        } else {
            apply()
            needsLayout = true
        }
    }
}
