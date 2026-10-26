import Foundation
import Combine
import UIKit
import ArtsyEngine

/// The one document of this first slice: the engine's context, a view model and a
/// renderer, opened from `Documents/Untitled.artsy` when there is one and made fresh
/// otherwise, and saved there whenever the app goes away.
final class PaintingSession: ObservableObject {
    let context: MetalContext?
    let viewModel: CanvasViewModel
    let renderer: CanvasRenderer?
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
        self.context = failure == nil ? context : nil
        self.renderer = failure == nil ? renderer : nil
        self.viewModel = viewModel ?? CanvasViewModel(canvasSize: Self.canvasSize)
        self.failure = failure
        self.viewModel.currentBrush = .pencil
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
