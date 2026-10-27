import Foundation
import Combine
import UIKit
import ArtsyEngine

/// A document on the screen: its view model and renderer over the app's Metal context,
/// the painting view, and what the chrome asks of them. Opened from the URL the document
/// browser hands over, or made blank at a size for a new document; saved to its URL when
/// it has been drawn on, every half minute between strokes, when the app goes to the
/// background, and when it closes.
final class PaintingSession: ObservableObject {
    let context: MetalContext
    let viewModel: CanvasViewModel
    let renderer: CanvasRenderer
    let paintingView: PaintingView
    let previews: BrushPreviewCache
    let chrome = ChromeState()
    private(set) var actions = ChromeActions()
    /// Whether the document's URL came under a security scope, given back when it closes.
    private let scoped: Bool
    private var autosave: Timer?
    private var saving = false

    enum Source {
        /// A document on disk, from the browser.
        case document(URL)
        /// A new canvas, not yet anywhere.
        case blank(CGSize)
    }

    static let autosaveInterval: TimeInterval = 30

    init(_ source: Source, context: MetalContext, previews: BrushPreviewCache, app: @escaping (String) -> Void) throws {
        self.context = context
        self.previews = previews
        switch source {
        case .document(let url):
            let scoped = url.startAccessingSecurityScopedResource()
            do {
                let opened = try CanvasDocument.load(from: url, metalContext: context)
                viewModel = opened.viewModel
                renderer = opened.renderer
            } catch {
                if scoped { url.stopAccessingSecurityScopedResource() }
                throw error
            }
            self.scoped = scoped
            viewModel.fileURL = url
            // The layer list shows what was opened, as on the Mac
            if let stack = viewModel.layerStack { renderer.updateAllThumbnails(in: stack) }
        case .blank(let size):
            let fresh = CanvasViewModel(canvasSize: size)
            let drawn = try CanvasRenderer(context: context, canvasSize: size)
            drawn.viewModel = fresh
            try drawn.setupLayerStack(for: fresh)
            viewModel = fresh
            renderer = drawn
            scoped = false
        }
        viewModel.markClean()
        viewModel.currentBrush = .pencil
        paintingView = PaintingView(frame: .zero, context: context, viewModel: viewModel, renderer: renderer)
        actions = Self.actions(for: paintingView, viewModel: viewModel, app: app)
        autosave = Timer.scheduledTimer(withTimeInterval: Self.autosaveInterval, repeats: true) { [weak self] _ in
            self?.saveIfDirty()
        }
    }

    deinit {
        autosave?.invalidate()
    }

    /// What the chrome asks of this screen: the canvas's size and undo, the view model's
    /// view and guides, the app's actions. Weak, so the chrome keeps nothing alive.
    private static func actions(for view: PaintingView, viewModel: CanvasViewModel, app: @escaping (String) -> Void) -> ChromeActions {
        var actions = ChromeActions()
        actions.renderer = { [weak view] in view?.renderer }
        actions.undo = { [weak view, weak viewModel] in
            guard let renderer = view?.renderer else { return }
            viewModel?.performUndo(renderer: renderer)
        }
        actions.redo = { [weak view, weak viewModel] in
            guard let renderer = view?.renderer else { return }
            viewModel?.performRedo(renderer: renderer)
        }
        actions.zoomToFit = { [weak view, weak viewModel] in
            guard let view else { return }
            viewModel?.zoomToFit(viewSize: view.bounds.size)
        }
        actions.actualSize = { [weak viewModel] in viewModel?.actualSize() }
        actions.rotate = { [weak view, weak viewModel] direction in
            guard let view else { return }
            viewModel?.rotateView(direction: direction, viewSize: view.bounds.size)
        }
        actions.resetRotation = { [weak view, weak viewModel] in
            guard let view else { return }
            viewModel?.resetRotation(viewSize: view.bounds.size)
        }
        actions.flip = { [weak view, weak viewModel] in
            guard let view else { return }
            viewModel?.flipView(viewSize: view.bounds.size)
        }
        actions.resetView = { [weak view, weak viewModel] in
            guard let view else { return }
            viewModel?.resetView(viewSize: view.bounds.size)
        }
        // Guides are kept but not yet drawn on iPad
        actions.changeGuides = { [weak viewModel] change in viewModel?.changeGuides(change) }
        actions.addGuide = { [weak view, weak viewModel] horizontal in
            guard let view else { return }
            viewModel?.addGuide(horizontal: horizontal, viewSize: view.bounds.size)
        }
        actions.app = app
        return actions
    }

    /// Zooms about the middle of the view, for the keyboard.
    func zoom(by factor: CGFloat) {
        let bounds = paintingView.bounds
        viewModel.transform.zoom(by: factor, at: CGPoint(x: bounds.midX, y: bounds.midY), viewSize: bounds.size)
    }

    // MARK: - Saving

    /// Saves to the document's URL. The canvas is marked clean only if nothing changed
    /// while the save was in flight.
    func save(completion: ((Bool) -> Void)? = nil) {
        guard let url = viewModel.fileURL, !saving else { completion?(false); return }
        saving = true
        let version = viewModel.contentVersion
        // Going to the background, the app has only moments before it is suspended; a
        // background task buys the save the seconds it needs
        let task = UIApplication.shared.beginBackgroundTask(withName: "Save \(url.lastPathComponent)")
        CanvasDocument.saveAsync(renderer: renderer, viewModel: viewModel, to: url) { [weak self] result in
            self?.saving = false
            var saved = false
            if case .success = result {
                saved = true
                if let size = self?.viewModel.canvasSize { RecentCanvases.shared.note(url, size: size) }
                if self?.viewModel.contentVersion == version { self?.viewModel.markClean() }
            }
            if task != .invalid { UIApplication.shared.endBackgroundTask(task) }
            completion?(saved)
        }
    }

    /// Writes the document at `url`, wherever that is: a new document's first home.
    func write(to url: URL, completion: @escaping (Result<Void, Error>) -> Void) {
        CanvasDocument.saveAsync(renderer: renderer, viewModel: viewModel, to: url, completion: completion)
    }

    /// Between strokes, a dirty document is saved.
    func saveIfDirty() {
        guard viewModel.isDirty, !viewModel.isDrawing else { return }
        save()
    }

    /// Saves if there is anything to save, then gives the document back.
    func close(completion: @escaping () -> Void = {}) {
        autosave?.invalidate()
        autosave = nil
        let finish = { [self] in
            if scoped, let url = viewModel.fileURL { url.stopAccessingSecurityScopedResource() }
            completion()
        }
        if viewModel.isDirty {
            save { _ in finish() }
        } else {
            finish()
        }
    }
}
