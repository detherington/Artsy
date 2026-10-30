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
    /// The canvas screen's controller, which sheets, pickers and share sheets come up over.
    weak var presenter: UIViewController?
    /// The Studio's model while its sheet is up.
    var studioModel: BrushStudioModel?
    /// A picker's delegate while the picker is up.
    var pickerDelegate: AnyObject?

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

    /// The largest canvas, per side, this device takes: by the GPU's working set.
    var largestCanvasSide: Int {
        guard let context else { return LayerStack.maxCanvasSide }
        return LayerStack.largestCanvasSide(memoryBudget: TextureManager.memoryBudget(for: context.device))
    }

    enum Failure: LocalizedError {
        case noEngine
        case couldNotWrite
        /// A canvas with more pixels than this device takes (its textures would be killed
        /// for their memory, not refused).
        case tooLarge(width: Int, height: Int, side: Int)
        var errorDescription: String? {
            switch self {
            case .noEngine: return "The drawing engine could not start"
            case .couldNotWrite: return "The canvas could not be written"
            case .tooLarge(let width, let height, let side):
                return "A \(width) × \(height) canvas is more than this device takes: up to \(side) × \(side)."
            }
        }
    }

    /// The error for a canvas of `size` this device cannot take, or nil for one it can.
    func tooLarge(_ width: Int, _ height: Int) -> Failure? {
        let side = largestCanvasSide
        return max(width, height) > side ? .tooLarge(width: width, height: height, side: side) : nil
    }

    /// The app's own folder: On My iPad ▸ Artsy in Files, where new canvases go.
    var documentsDirectory: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].standardizedFileURL
    }

    func isInDocuments(_ url: URL) -> Bool {
        url.standardizedFileURL.path.hasPrefix(documentsDirectory.path + "/")
    }

    /// A new canvas of `size`, "Canvas N" in Documents, written and opened; `remember`
    /// makes the size the start screen's "Same as last" (not for a photo's).
    func newCanvas(size: CGSize, remember: Bool = true, completion: @escaping (Result<PaintingSession, Error>) -> Void) {
        if let failure = tooLarge(Int(size.width), Int(size.height)) { completion(.failure(failure)); return }
        if remember { AppPreferences.shared.lastCanvasSize = size }
        let folder = documentsDirectory
        var n = 1
        while FileManager.default.fileExists(atPath: folder.appendingPathComponent("Canvas \(n).artsy").path) { n += 1 }
        let url = folder.appendingPathComponent("Canvas \(n).artsy")
        create(size: size, at: url) { [weak self] made in
            guard let self else { return }
            guard made else { completion(.failure(Failure.couldNotWrite)); return }
            do { completion(.success(try self.open(url))) } catch { completion(.failure(error)) }
        }
    }

    /// A canvas of the app's own renamed on disk, in the list, and in the open session.
    func rename(_ entry: RecentCanvases.Entry, to name: String) {
        guard !name.isEmpty, !name.contains("/"), let url = RecentCanvases.shared.url(of: entry), isInDocuments(url) else { return }
        let destination = url.deletingLastPathComponent().appendingPathComponent(name).appendingPathExtension("artsy")
        guard destination.path != url.path else { return }
        do {
            try FileManager.default.moveItem(at: url, to: destination)
        } catch {
            DiagnosticsLog.shared.error(error, doing: "renaming \(entry.name)")
            return
        }
        RecentCanvases.shared.moved(entry, to: destination)
        if session?.viewModel.fileURL?.standardizedFileURL.path == url.standardizedFileURL.path {
            session?.viewModel.fileURL = destination
        }
    }

    /// Opens the document at `url` as the session on the screen.
    func open(_ url: URL) throws -> PaintingSession {
        guard let context else { throw Failure.noEngine }
        if let open = session { open.close() }
        // A document from a bigger device is refused with a word, not killed for its memory
        let size = CanvasDocument.canvasSize(of: try CanvasDocument.read(from: url))
        if let failure = tooLarge(Int(size.width), Int(size.height)) { throw failure }
        let session = try PaintingSession(.document(url), context: context, previews: previews) { [weak self] name in
            self?.app(name)
        }
        self.session = session
        RecentCanvases.shared.note(url, size: session.viewModel.canvasSize)
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
}
