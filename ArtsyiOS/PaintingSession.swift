import Foundation
import Combine
import UIKit
import ArtsyEngine

/// The one document of this first slice: the engine's context, a view model and a
/// renderer, opened from `Documents/Untitled.artsy` when there is one and made fresh
/// otherwise, and saved there whenever the app goes away. The painting view and what
/// the chrome asks of it are made here too, so the screen can compose them.
final class PaintingSession: ObservableObject {
    let context: MetalContext?
    let viewModel: CanvasViewModel
    let renderer: CanvasRenderer?
    let paintingView: PaintingView?
    let previews: BrushPreviewCache
    let chrome = ChromeState()
    let actions: ChromeActions
    /// What went wrong making the engine, if anything did: shown in place of the canvas.
    let failure: String?

    static let canvasSize = CGSize(width: 2048, height: 1536)

    static var documentURL: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("Untitled.artsy")
    }

    init() {
        var context: MetalContext?
        var viewModel: CanvasViewModel?
        var renderer: CanvasRenderer?
        var failure: String?
        do {
            let made = try MetalContext()
            context = made
            DiagnosticsLog.shared.launched(device: made.device)
            if FileManager.default.fileExists(atPath: Self.documentURL.path),
               let opened = try? CanvasDocument.load(from: Self.documentURL, metalContext: made) {
                viewModel = opened.viewModel
                renderer = opened.renderer
                // The layer list shows what was opened, as on the Mac
                if let stack = opened.viewModel.layerStack { opened.renderer.updateAllThumbnails(in: stack) }
            } else {
                let fresh = CanvasViewModel(canvasSize: Self.canvasSize)
                let drawn = try CanvasRenderer(context: made, canvasSize: fresh.canvasSize)
                drawn.viewModel = fresh
                try drawn.setupLayerStack(for: fresh)
                viewModel = fresh
                renderer = drawn
            }
        } catch {
            failure = "\(error)"
            DiagnosticsLog.shared.error(error, doing: "starting the engine")
        }
        let model = viewModel ?? CanvasViewModel(canvasSize: Self.canvasSize)
        self.context = failure == nil ? context : nil
        self.renderer = failure == nil ? renderer : nil
        self.viewModel = model
        self.failure = failure
        model.currentBrush = .pencil

        if let context = self.context, let renderer = self.renderer {
            let view = PaintingView(frame: .zero, context: context, viewModel: model, renderer: renderer)
            paintingView = view
            previews = BrushPreviewCache(renderer: try? BrushPreview(context: context, size: BrushPreviewCache.size))
            actions = Self.actions(for: view, viewModel: model)
        } else {
            paintingView = nil
            previews = BrushPreviewCache(renderer: nil)
            actions = ChromeActions()
        }
        // The panel's tiles, ready before its first open; never under a stroke
        previews.warm(BrushLibrary.shared.all) { model.isDrawing }
    }

    /// What the chrome asks of this screen: the canvas's size and undo, the view model's
    /// view and guides. Weak, so the chrome keeps nothing alive.
    private static func actions(for view: PaintingView, viewModel: CanvasViewModel) -> ChromeActions {
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
        return actions
    }

    func save() {
        guard let renderer else { return }
        // Going to the background, the app has only moments before it is suspended; a
        // background task buys the save the seconds it needs
        let task = UIApplication.shared.beginBackgroundTask(withName: "Save Untitled.artsy")
        CanvasDocument.saveAsync(renderer: renderer, viewModel: viewModel, to: Self.documentURL) { result in
            if case .failure(let error) = result { DiagnosticsLog.shared.error(error, doing: "saving Untitled.artsy") }
            if task != .invalid { UIApplication.shared.endBackgroundTask(task) }
        }
    }
}
