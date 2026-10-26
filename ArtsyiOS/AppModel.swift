import Foundation
import Combine
import UIKit
import ArtsyEngine

/// The app on iPad and iPhone: the one Metal context, the brush previews shared by every
/// document, and the document open on the screen, if one is. The document browser is the
/// screen behind the canvas; opening a document makes a session, closing it saves and
/// drops it.
final class AppModel: ObservableObject {
    let context: MetalContext?
    /// What went wrong making the engine, if anything did: shown in place of the app.
    let failure: String?
    let previews: BrushPreviewCache
    @Published private(set) var session: PaintingSession?
    /// Takes the canvas screen down; set by whoever put it up.
    var dismissCanvas: (() -> Void)?

    init() {
        do {
            let made = try MetalContext()
            context = made
            failure = nil
            DiagnosticsLog.shared.launched(device: made.device)
            previews = BrushPreviewCache(renderer: try? BrushPreview(context: made, size: BrushPreviewCache.size))
        } catch {
            context = nil
            failure = "\(error)"
            previews = BrushPreviewCache(renderer: nil)
            DiagnosticsLog.shared.error(error, doing: "starting the engine")
        }
        // The panel's tiles, ready before its first open; never under a stroke
        previews.warm(BrushLibrary.shared.all) { [weak self] in self?.session?.viewModel.isDrawing ?? false }
    }

    enum Failure: LocalizedError {
        case noEngine
        var errorDescription: String? { "The drawing engine could not start" }
    }

    /// Opens the document at `url` as the session on the screen.
    func open(_ url: URL) throws -> PaintingSession {
        guard let context else { throw Failure.noEngine }
        if let open = session { open.close() }
        let session = try PaintingSession(.document(url), context: context, previews: previews) { [weak self] name in
            self?.handle(app: name)
        }
        self.session = session
        return session
    }

    /// A new document of `size` written at `url`, for the browser to move where the user
    /// chose; it is then opened from there like any other.
    func create(size: CGSize, at url: URL, completion: @escaping (Bool) -> Void) {
        guard let context else { completion(false); return }
        do {
            let fresh = try PaintingSession(.blank(size), context: context, previews: previews) { _ in }
            fresh.write(to: url) { result in
                withExtendedLifetime(fresh) {}
                if case .failure(let error) = result {
                    DiagnosticsLog.shared.error(error, doing: "creating \(url.lastPathComponent)")
                    completion(false)
                } else {
                    completion(true)
                }
            }
        } catch {
            DiagnosticsLog.shared.error(error, doing: "making a new canvas")
            completion(false)
        }
    }

    /// Saves the open document and takes its screen down.
    func closeDocument() {
        guard let session else { return }
        session.close { [weak self] in
            self?.session = nil
            self?.dismissCanvas?()
        }
    }

    /// The app-level actions the chrome asks for by the Mac's selector names.
    private func handle(app name: String) {
        switch name {
        case "handleSave":
            session?.save()
        case "handleOpen", "showNewCanvasDialog":
            closeDocument()
        default:
            DiagnosticsLog.shared.note(.app, "\(name) is not on iPad yet")
        }
    }
}
