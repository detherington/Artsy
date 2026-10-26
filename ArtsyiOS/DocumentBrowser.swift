import SwiftUI
import UIKit
import UniformTypeIdentifiers
import ArtsyEngine

extension UTType {
    /// The `.artsy` package, declared by the app.
    static let artsyDocument = UTType(exportedAs: "com.artsy.document")
}

/// The documents: the system's browser over iCloud Drive, On My iPad and any other
/// provider, which creates, picks and imports `.artsy` documents. A picked document opens
/// as the canvas screen over it; a new one is made at the size chosen in the Mac's
/// new-canvas view and moved by the browser to where the user put it.
struct DocumentBrowser: UIViewControllerRepresentable {
    let model: AppModel

    func makeUIViewController(context: Context) -> UIDocumentBrowserViewController {
        let browser = UIDocumentBrowserViewController(forOpening: [.artsyDocument])
        browser.allowsDocumentCreation = true
        browser.allowsPickingMultipleItems = false
        browser.shouldShowFileExtensions = false
        browser.browserUserInterfaceStyle = .dark
        browser.overrideUserInterfaceStyle = .dark
        browser.delegate = context.coordinator
        return browser
    }

    func updateUIViewController(_ browser: UIDocumentBrowserViewController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(model: model) }

    final class Coordinator: NSObject, UIDocumentBrowserViewControllerDelegate {
        let model: AppModel

        init(model: AppModel) { self.model = model }

        func documentBrowser(_ controller: UIDocumentBrowserViewController,
                             didRequestDocumentCreationWithHandler importHandler: @escaping (URL?, UIDocumentBrowserViewController.ImportMode) -> Void) {
            // The browser waits for exactly one answer; the sheet cannot be swiped away
            var sheet: UIViewController?
            let picker = NewCanvasView(
                onCreate: { [weak self] size in
                    sheet?.dismiss(animated: true)
                    let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
                    let url = folder.appendingPathComponent("Untitled.artsy")
                    do {
                        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                    } catch {
                        DiagnosticsLog.shared.error(error, doing: "making room for a new canvas")
                        importHandler(nil, .none)
                        return
                    }
                    self?.model.create(size: size, at: url) { made in
                        importHandler(made ? url : nil, made ? .move : .none)
                    }
                },
                onOpen: nil,
                onCancel: {
                    sheet?.dismiss(animated: true)
                    importHandler(nil, .none)
                }
            )
            .preferredColorScheme(.dark)
            let host = UIHostingController(rootView: picker)
            host.modalPresentationStyle = .formSheet
            host.overrideUserInterfaceStyle = .dark
            host.isModalInPresentation = true
            host.preferredContentSize = CGSize(width: 400, height: 520)
            sheet = host
            controller.present(host, animated: true)
        }

        func documentBrowser(_ controller: UIDocumentBrowserViewController, didPickDocumentsAt documentURLs: [URL]) {
            guard let url = documentURLs.first else { return }
            open(url, from: controller)
        }

        func documentBrowser(_ controller: UIDocumentBrowserViewController, didImportDocumentAt sourceURL: URL, toDestinationURL destinationURL: URL) {
            open(destinationURL, from: controller)
        }

        func documentBrowser(_ controller: UIDocumentBrowserViewController, failedToImportDocumentAt documentURL: URL, error: Error?) {
            if let error { DiagnosticsLog.shared.error(error, doing: "placing \(documentURL.lastPathComponent)") }
            show("Could not make \(documentURL.lastPathComponent)", error?.localizedDescription ?? "The document could not be placed there.", from: controller)
        }

        /// The canvas screen over the browser, with the document in it.
        private func open(_ url: URL, from controller: UIDocumentBrowserViewController) {
            do {
                let session = try model.open(url)
                let screen = CanvasHostingController(rootView: CanvasScreen(session: session))
                screen.modalPresentationStyle = .fullScreen
                screen.overrideUserInterfaceStyle = .dark
                screen.keys = KeyCommands.entries(for: session) { [weak model] name in model?.app(name) }
                model.presenter = screen
                model.dismissCanvas = { [weak controller] in controller?.dismiss(animated: true) }
                controller.present(screen, animated: true)
            } catch {
                DiagnosticsLog.shared.error(error, doing: "opening \(url.lastPathComponent)")
                show("Could not open \(url.deletingPathExtension().lastPathComponent)", error.localizedDescription, from: controller)
            }
        }

        private func show(_ title: String, _ message: String, from controller: UIViewController) {
            let alert = UIAlertController(title: title, message: message, preferredStyle: .alert)
            alert.addAction(UIAlertAction(title: "OK", style: .default))
            controller.present(alert, animated: true)
        }
    }
}

/// The canvas screen as a view controller: full screen, no status bar, and the keys a
/// keyboard sends, held as the Mac's shortcuts.
final class CanvasHostingController: UIHostingController<CanvasScreen> {
    var keys: [KeyCommands.Entry] = [] {
        didSet {
            commands = keys.map { entry in
                let command = UIKeyCommand(title: entry.title, action: #selector(runKey(_:)), input: entry.input,
                                           modifierFlags: entry.modifiers, propertyList: entry.id)
                command.wantsPriorityOverSystemBehavior = entry.overridesSystem
                return command
            }
        }
    }
    private var commands: [UIKeyCommand] = []

    override var prefersStatusBarHidden: Bool { true }
    override var keyCommands: [UIKeyCommand]? { commands }
    override var canBecomeFirstResponder: Bool { true }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        becomeFirstResponder()
    }

    @objc private func runKey(_ command: UIKeyCommand) {
        guard let id = command.propertyList as? String, let entry = keys.first(where: { $0.id == id }) else { return }
        entry.run()
    }
}
