import SwiftUI
import Combine
import UIKit
import UniformTypeIdentifiers
import ArtsyEngine

extension UTType {
    /// The `.artsy` package, declared by the app.
    static let artsyDocument = UTType(exportedAs: "com.artsy.document")
}

/// The documents elsewhere: the system's browser over iCloud Drive, On My iPad and any
/// other provider, presented from the start screen for picking, importing or creating
/// `.artsy` documents where the user wants them. A picked document is handed back to
/// the start screen, which takes the browser down and opens it; a new one is made at the
/// size chosen in the size dialog and moved by the browser to where the user put it.
enum DocumentBrowser {
    static func make(model: AppModel, onPick: @escaping (URL) -> Void) -> UIDocumentBrowserViewController {
        let browser = Browser(forOpening: [.artsyDocument])
        browser.allowsDocumentCreation = true
        browser.allowsPickingMultipleItems = false
        browser.shouldShowFileExtensions = false
        browser.browserUserInterfaceStyle = .dark
        browser.overrideUserInterfaceStyle = .dark
        let coordinator = Coordinator(model: model, onPick: onPick)
        coordinator.browser = browser
        browser.coordinator = coordinator
        browser.delegate = coordinator
        browser.additionalTrailingNavigationBarButtonItems = [
            UIBarButtonItem(barButtonSystemItem: .close, target: coordinator, action: #selector(Coordinator.close))
        ]
        return browser
    }

    /// The browser with its delegate kept alive beside it.
    final class Browser: UIDocumentBrowserViewController {
        var coordinator: Coordinator?
    }

    final class Coordinator: NSObject, UIDocumentBrowserViewControllerDelegate {
        let model: AppModel
        let onPick: (URL) -> Void
        weak var browser: UIDocumentBrowserViewController?

        init(model: AppModel, onPick: @escaping (URL) -> Void) {
            self.model = model
            self.onPick = onPick
        }

        @objc func close() {
            browser?.dismiss(animated: true)
        }

        func documentBrowser(_ controller: UIDocumentBrowserViewController,
                             didRequestDocumentCreationWithHandler importHandler: @escaping (URL?, UIDocumentBrowserViewController.ImportMode) -> Void) {
            // The browser waits for exactly one answer; the sheet cannot be swiped away
            var sheet: UIViewController?
            let picker = NewCanvasView(
                onCreate: { [weak self] size in
                    sheet?.dismiss(animated: true)
                    AppPreferences.shared.lastCanvasSize = size
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
                },
                maxSide: model.largestCanvasSide
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
            onPick(url)
        }

        func documentBrowser(_ controller: UIDocumentBrowserViewController, didImportDocumentAt sourceURL: URL, toDestinationURL destinationURL: URL) {
            onPick(destinationURL)
        }

        func documentBrowser(_ controller: UIDocumentBrowserViewController, failedToImportDocumentAt documentURL: URL, error: Error?) {
            if let error { DiagnosticsLog.shared.error(error, doing: "placing \(documentURL.lastPathComponent)") }
            let alert = UIAlertController(title: "Could not make \(documentURL.lastPathComponent)",
                                          message: error?.localizedDescription ?? "The document could not be placed there.", preferredStyle: .alert)
            alert.addAction(UIAlertAction(title: "OK", style: .default))
            controller.present(alert, animated: true)
        }
    }
}

/// The canvas screen as a view controller: full screen, no status bar, and the keys a
/// keyboard sends, held as the Mac's shortcuts. With the interface hidden the home
/// indicator fades too, and a swipe up from the bottom edge is the canvas's first, the
/// system's on the second, so a stroke that runs off the bottom does not leave the app.
final class CanvasHostingController: UIHostingController<CanvasScreen> {
    private var chromeHidden = false
    private var chromeWatch: AnyCancellable?

    /// Follows whether this canvas's interface is hidden.
    func follow(_ viewModel: CanvasViewModel) {
        chromeHidden = viewModel.isChromeHidden
        // Published values arrive before the property changes: the delivered one is the new one
        chromeWatch = viewModel.$isChromeHidden.dropFirst().sink { [weak self] hidden in
            self?.chromeHidden = hidden
            self?.setNeedsUpdateOfHomeIndicatorAutoHidden()
            self?.setNeedsUpdateOfScreenEdgesDeferringSystemGestures()
        }
    }

    override var prefersHomeIndicatorAutoHidden: Bool { chromeHidden }
    override var preferredScreenEdgesDeferringSystemGestures: UIRectEdge { chromeHidden ? .bottom : [] }

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
