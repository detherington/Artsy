import Combine
import SwiftUI
import UIKit
import PhotosUI
import UniformTypeIdentifiers
import ArtsyEngine

/// The start screen as the app's root: `StartView` in a hosting controller that puts
/// the canvas screen up over it, the Files browser for documents elsewhere, and the
/// size dialog for a canvas of one's own size. See `docs/start-screen-plan.md`.
struct StartScreen: UIViewControllerRepresentable {
    let model: AppModel

    func makeUIViewController(context: Context) -> StartController { StartController(model: model) }

    func updateUIViewController(_ controller: StartController, context: Context) {}
}

final class StartController: UIHostingController<StartView> {
    private let model: AppModel
    /// Follows the appearance setting into this screen, its window and what it presents.
    private var appearanceObservation: AnyCancellable?

    init(model: AppModel) {
        self.model = model
        super.init(rootView: StartView(recents: .shared, maxSide: model.largestCanvasSide, actions: StartActions()))
        overrideUserInterfaceStyle = Chrome.interfaceStyle
        view.backgroundColor = UIColor(Chrome.background)
        appearanceObservation = AppPreferences.shared.$appearance.dropFirst().sink { [weak self] _ in self?.applyAppearance() }
        var actions = StartActions()
        actions.newCanvas = { [weak self] size in self?.newCanvas(size: size) }
        actions.fullScreen = { [weak self] size in self?.newCanvas(size: size, fullScreen: true) }
        actions.customCanvas = { [weak self] in self?.showSizeDialog() }
        actions.open = { [weak self] entry in self?.openRecent(entry) }
        actions.browse = { [weak self] in self?.browse() }
        actions.browseTitle = "Browse…"
        actions.reveal = { entry in
            // The Files app, at the document
            guard let url = RecentCanvases.shared.url(of: entry),
                  let files = URL(string: "shareddocuments://" + url.path) else { return }
            UIApplication.shared.open(files)
        }
        actions.canRename = { [weak self] entry in
            guard let self, let url = RecentCanvases.shared.url(of: entry) else { return false }
            return self.model.isInDocuments(url)
        }
        actions.rename = { [weak self] entry, name in self?.model.rename(entry, to: name) }
        actions.fromPhotos = { [weak self] in self?.newCanvasFromPhotos() }
        actions.fromImageFile = { [weak self] in self?.newCanvasFromImageFile() }
        rootView = StartView(recents: .shared, maxSide: model.largestCanvasSide,
                             screenPixels: { [weak self] in self?.screenPixels }, actions: actions)
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        // The window is there now: the style goes on it too, so the status bar and anything
        // presented over this screen follow
        applyAppearance()
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        applyAppearance()
    }

    /// The appearance setting, onto this screen, the window and whatever is presented over it.
    private func applyAppearance() {
        let style = Chrome.interfaceStyle
        overrideUserInterfaceStyle = style
        // The windows too: a popover or a sheet takes its appearance from the window it is
        // presented in, not from this screen
        for scene in UIApplication.shared.connectedScenes {
            (scene as? UIWindowScene)?.windows.forEach { $0.overrideUserInterfaceStyle = style }
        }
        presentedViewController?.overrideUserInterfaceStyle = style
    }

    /// The pixels of the screen this controller is on, the way the device is held: on a
    /// foldable the display that is open. Before the view is in a window, the scene's.
    private var screenPixels: CGSize? {
        let screen = view.window?.windowScene?.screen
            ?? UIApplication.shared.connectedScenes.lazy.compactMap { $0 as? UIWindowScene }.first?.screen
        guard let screen else { return nil }
        let scale = screen.nativeScale
        return CGSize(width: (screen.bounds.width * scale).rounded(), height: (screen.bounds.height * scale).rounded())
    }

    /// A picker's delegate while the picker is up.
    private var pickerDelegate: AnyObject?

    // MARK: - From a photo

    private func newCanvasFromPhotos() {
        var configuration = PHPickerConfiguration(photoLibrary: .shared())
        configuration.filter = .images
        configuration.selectionLimit = 1
        let picker = PHPickerViewController(configuration: configuration)
        let delegate = PhotoPickerDelegate { [weak self] data, name in self?.newCanvas(imageData: data, named: name) }
        pickerDelegate = delegate
        picker.delegate = delegate
        present(picker, animated: true)
    }

    private func newCanvasFromImageFile() {
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: [.image], asCopy: true)
        let delegate = DocumentPickerDelegate { [weak self] urls in
            guard let url = urls.first else { return }
            guard let data = try? Data(contentsOf: url) else {
                self?.show("Could not read \(url.lastPathComponent)", "The file could not be read.")
                return
            }
            self?.newCanvas(imageData: data, named: url.deletingPathExtension().lastPathComponent)
        }
        pickerDelegate = delegate
        picker.delegate = delegate
        present(picker, animated: true)
    }

    /// A canvas of the photo's size with the photo as its first layer, opened.
    private func newCanvas(imageData: Data, named name: String) {
        guard let image = PhotoCanvas.image(from: imageData, maxSide: model.largestCanvasSide) else {
            show("Could not read the photo", PhotoCanvas.Failure.undecodable.localizedDescription)
            return
        }
        model.newCanvas(size: PhotoCanvas.canvasSize(for: image), remember: false) { [weak self] result in
            switch result {
            case .success(let session):
                do {
                    try PhotoCanvas.place(image, named: name, in: session.viewModel, renderer: session.renderer)
                } catch {
                    DiagnosticsLog.shared.error(error, doing: "placing \(name)")
                }
                self?.show(session)
            case .failure(let error):
                self?.show("Could not make a canvas", error.localizedDescription)
            }
        }
    }

    @objc required dynamic init?(coder aDecoder: NSCoder) { fatalError("init(coder:) is not supported") }

    // MARK: - Canvases

    /// `fullScreen` opens it as the screen: the interface away and the canvas edge to
    /// edge, which for the screen's own pixels is pixel for pixel.
    private func newCanvas(size: CGSize, fullScreen: Bool = false) {
        model.newCanvas(size: size) { [weak self] result in
            switch result {
            case .success(let session):
                if fullScreen { session.viewModel.fillScreen() }
                self?.show(session)
            case .failure(let error): self?.show("Could not make a canvas", error.localizedDescription)
            }
        }
    }

    /// A canvas from the list: opened if it is still there, else a word and the entry
    /// offered for removal.
    private func openRecent(_ entry: RecentCanvases.Entry) {
        guard let url = RecentCanvases.shared.url(of: entry) else {
            let alert = UIAlertController(title: "\(entry.name) was not found", message: "It may have been moved or deleted.", preferredStyle: .alert)
            alert.addAction(UIAlertAction(title: "Remove from Recents", style: .destructive) { _ in RecentCanvases.shared.remove(entry) })
            alert.addAction(UIAlertAction(title: "Keep", style: .cancel))
            present(alert, animated: true)
            return
        }
        open(url)
    }

    func open(_ url: URL) {
        do {
            show(try model.open(url))
        } catch {
            DiagnosticsLog.shared.error(error, doing: "opening \(url.lastPathComponent)")
            show("Could not open \(url.deletingPathExtension().lastPathComponent)", error.localizedDescription)
        }
    }

    /// The canvas screen over this one, with the session in it.
    private func show(_ session: PaintingSession) {
        let screen = CanvasHostingController(rootView: CanvasScreen(session: session))
        screen.modalPresentationStyle = .fullScreen
        screen.overrideUserInterfaceStyle = Chrome.interfaceStyle
        screen.keys = KeyCommands.entries(for: session) { [weak model] name in model?.app(name) }
        screen.follow(session.viewModel)
        model.presenter = screen
        model.dismissCanvas = { [weak self] in self?.dismiss(animated: true) }
        present(screen, animated: true)
    }

    // MARK: - Elsewhere, and a size of one's own

    /// The Files browser, for a document anywhere: picked, it comes up here once the
    /// browser is down.
    private func browse() {
        let browser = DocumentBrowser.make(model: model) { [weak self] url in
            self?.dismiss(animated: true) { self?.open(url) }
        }
        browser.modalPresentationStyle = .fullScreen
        present(browser, animated: true)
    }

    private func showSizeDialog() {
        var sheet: UIViewController?
        let picker = NewCanvasView(
            onCreate: { [weak self] size in
                sheet?.dismiss(animated: true) { self?.newCanvas(size: size) }
            },
            onOpen: nil,
            onCancel: { sheet?.dismiss(animated: true) },
            maxSide: model.largestCanvasSide
        )
        .preferredColorScheme(.dark)
        let host = UIHostingController(rootView: picker)
        host.modalPresentationStyle = .formSheet
        host.overrideUserInterfaceStyle = Chrome.interfaceStyle
        host.preferredContentSize = CGSize(width: 400, height: 520)
        sheet = host
        present(host, animated: true)
    }

    private func show(_ title: String, _ message: String) {
        let alert = UIAlertController(title: title, message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "OK", style: .default))
        present(alert, animated: true)
    }
}
