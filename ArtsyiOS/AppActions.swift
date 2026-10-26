import SwiftUI
import UIKit
import PhotosUI
import UniformTypeIdentifiers
import ArtsyEngine

// The app-level actions the chrome asks for by the Mac's selector names: what the Mac
// does with windows, panels and the menu bar, done on iPad with sheets over the canvas
// screen, the Photos and document pickers, and the share sheet.
extension AppModel {
    func app(_ name: String) {
        switch name {
        case "handleSave":
            session?.save()
        case "handleOpen", "showNewCanvasDialog":
            closeDocument()
        case "showBrushStudio":
            showStudio()
        case "showSettings":
            present(sheet: SettingsView(), size: CGSize(width: 480, height: 560))
        case "showShortcuts":
            present(sheet: ShortcutsView(), size: CGSize(width: 420, height: 640))
        case "handleExportPNG":
            export(.png(bitsPerChannel: 8))
        case "handleExportPNG16":
            export(.png(bitsPerChannel: 16))
        case "handleExportJPEG":
            export(.jpeg)
        case "handleExportBrush":
            exportBrush()
        case "handleImportImage":
            importImage()
        case "handleImportBrush":
            importBrushes()
        case "handleImportTexture":
            importTextures()
        default:
            DiagnosticsLog.shared.note(.app, "\(name) is not on iPad yet")
        }
    }

    // MARK: - Sheets

    /// Whatever is on top of the canvas screen, for the next thing to come up over.
    private var top: UIViewController? {
        var controller = presenter
        while let above = controller?.presentedViewController, !above.isBeingDismissed { controller = above }
        return controller
    }

    /// Presents once the panel that asked for it has gone: a panel's row tapped
    /// closes the panel, but only on the next layout pass, and a sheet or picker put
    /// up on the panel in the meantime goes down with it. Whatever is still up after
    /// a moment, a sheet of the app's own, takes the new one on top.
    private func present(_ controller: UIViewController, attempt: Int = 0) {
        guard let presenter else { return }
        if presenter.presentedViewController != nil, attempt < 10 {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in self?.present(controller, attempt: attempt + 1) }
            return
        }
        top?.present(controller, animated: true)
    }

    private func present<Content: View>(sheet content: Content, size: CGSize) {
        // A little room under the sheet's top edge, which the Mac's windows had in their title bars
        let host = UIHostingController(rootView: content.padding(.top, 16))
        host.modalPresentationStyle = .formSheet
        host.preferredContentSize = size
        host.overrideUserInterfaceStyle = .dark
        present(host)
    }

    /// The Studio on the open document's current brush, as on the Mac.
    private func showStudio() {
        guard let session, let context else { return }
        let model = BrushStudioModel(viewModel: session.viewModel, library: BrushLibrary.shared,
                                     previewRenderer: try? BrushPreview(context: context))
        studioModel = model
        present(sheet: BrushStudioView(model: model, library: BrushLibrary.shared), size: CGSize(width: 460, height: 760))
    }

    private func show(_ error: Error, doing what: String) {
        DiagnosticsLog.shared.error(error, doing: what)
        alert("Could not finish \(what)", error.localizedDescription)
    }

    private func alert(_ title: String, _ message: String) {
        let alert = UIAlertController(title: title, message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "OK", style: .default))
        present(alert)
    }

    // MARK: - Export

    enum ExportKind {
        case png(bitsPerChannel: Int)
        case jpeg
    }

    /// The lit canvas as an image file in a folder of its own, offered through the share
    /// sheet: Files, Photos, Mail and the rest.
    private func export(_ kind: ExportKind) {
        guard let session else { return }
        ChromeActions.commitPendingEdits()
        let name = session.viewModel.displayName
        do {
            let folder = try Self.scratchFolder()
            let url: URL
            switch kind {
            case .png(let bits):
                url = folder.appendingPathComponent(bits == 16 ? "\(name) 16-bit.png" : "\(name).png")
                try ImageExporter.exportPNG(renderer: session.renderer, to: url, bitsPerChannel: bits)
            case .jpeg:
                url = folder.appendingPathComponent("\(name).jpg")
                try ImageExporter.exportJPEG(renderer: session.renderer, to: url)
            }
            share([url])
        } catch {
            show(error, doing: "exporting \(name)")
        }
    }

    /// The current brush as a file, through the share sheet.
    private func exportBrush() {
        guard let session else { return }
        let brush = session.viewModel.currentBrush
        do {
            let url = try Self.scratchFolder().appendingPathComponent("\(brush.name).\(BrushLibrary.fileExtension)")
            try BrushLibrary.shared.export(brush, to: url)
            share([url])
        } catch {
            show(error, doing: "exporting \(brush.name)")
        }
    }

    private static func scratchFolder() throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    private func share(_ items: [Any]) {
        guard let presenter else { return }
        let sheet = UIActivityViewController(activityItems: items, applicationActivities: nil)
        // On iPad the share sheet is a popover: from the document menu's corner of the bar
        sheet.popoverPresentationController?.sourceView = presenter.view
        sheet.popoverPresentationController?.sourceRect = CGRect(x: 40, y: presenter.view.bounds.height - 30, width: 1, height: 1)
        sheet.popoverPresentationController?.permittedArrowDirections = .down
        present(sheet)
    }

    // MARK: - Import

    /// A photo as a new layer above the current one, fitted to the canvas.
    private func importImage() {
        var configuration = PHPickerConfiguration(photoLibrary: .shared())
        configuration.filter = .images
        configuration.selectionLimit = 1
        let picker = PHPickerViewController(configuration: configuration)
        let delegate = PhotoPickerDelegate { [weak self] data, name in
            self?.place(imageData: data, named: name)
        }
        pickerDelegate = delegate
        picker.delegate = delegate
        present(picker)
    }

    private func place(imageData: Data, named name: String) {
        guard let session, let layerStack = session.viewModel.layerStack else { return }
        let viewModel = session.viewModel, renderer = session.renderer
        ChromeActions.commitPendingEdits()
        // Adding a layer is a step to undo; nothing already there changes
        viewModel.saveUndoSnapshot(renderer: renderer, description: "Import Image", changing: .nothing)
        let step = viewModel.undoManager.lastStepToken
        do {
            let index = try layerStack.addLayer(above: layerStack.activeLayerIndex, name: name)
            let layer = layerStack.layers[index]
            try renderer.fillLayerWithImageFitToCanvas(imageData: imageData, layer: layer)
            renderer.updateThumbnail(for: layer)
            viewModel.markDirty()
        } catch {
            viewModel.undoManager.popLastSnapshot(if: step)
            show(error, doing: "placing \(name)")
        }
    }

    /// Artsy brushes, Photoshop .abr files or Procreate .brush and .brushset files, from
    /// the document picker, into the library; the last one becomes the current brush.
    private func importBrushes() {
        let types = [BrushLibrary.brushType, .json] + ["abr", "brush", "brushset"].compactMap { UTType(filenameExtension: $0) }
        pick(types, multiple: true) { [weak self] urls in
            guard let self else { return }
            for url in urls {
                do {
                    let imported = try BrushLibrary.shared.importBrushes(from: url)
                    DiagnosticsLog.shared.note(.brush, "imported \(imported.count) from \(url.lastPathComponent): "
                                               + imported.map(\.name).joined(separator: ", "))
                    for case .stamp(let settings) in imported.map(\.rendering) {
                        if case .image(let name) = settings.tip { self.context?.brushTextures.forgetImage(named: name) }
                        if case .image(let name)? = settings.grain?.texture { self.context?.brushTextures.forgetImage(named: name) }
                    }
                    if let last = imported.last { self.session?.viewModel.currentBrush = last }
                } catch {
                    self.show(error, doing: "importing \(url.lastPathComponent)")
                }
            }
        }
    }

    /// Tip or grain images into the library's textures folder.
    private func importTextures() {
        pick([.image, UTType(filenameExtension: "gbr") ?? .data], multiple: true) { [weak self] urls in
            guard let self else { return }
            var names: [String] = []
            for url in urls {
                do {
                    let name = try BrushLibrary.shared.importTexture(from: url)
                    self.context?.brushTextures.forgetImage(named: name)
                    names.append(name)
                } catch {
                    self.show(error, doing: "importing \(url.lastPathComponent)")
                }
            }
            guard !names.isEmpty else { return }
            self.alert(names.count == 1 ? "Imported \(names[0])" : "Imported \(names.count) images",
                       "Refer to an image from a brush file as \"image:<name>\" for its tip or grain texture. Names: "
                       + names.joined(separator: ", "))
        }
    }

    /// The document picker, handing over copies so no security scope is needed.
    private func pick(_ types: [UTType], multiple: Bool, picked: @escaping ([URL]) -> Void) {
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: types, asCopy: true)
        picker.allowsMultipleSelection = multiple
        picker.overrideUserInterfaceStyle = .dark
        let delegate = DocumentPickerDelegate(picked: picked)
        pickerDelegate = delegate
        picker.delegate = delegate
        present(picker)
    }
}

/// The Photos picker's one answer: the picked image's data and name, on the main queue.
final class PhotoPickerDelegate: NSObject, PHPickerViewControllerDelegate {
    private let picked: (Data, String) -> Void

    init(picked: @escaping (Data, String) -> Void) { self.picked = picked }

    func picker(_ picker: PHPickerViewController, didFinishPicking results: [PHPickerResult]) {
        picker.dismiss(animated: true)
        guard let provider = results.first?.itemProvider else { return }
        let name = provider.suggestedName ?? "Photo"
        provider.loadDataRepresentation(forTypeIdentifier: UTType.image.identifier) { [picked] data, error in
            if let error { DiagnosticsLog.shared.error(error, doing: "reading \(name)") }
            guard let data else { return }
            DispatchQueue.main.async { picked(data, name) }
        }
    }
}

final class DocumentPickerDelegate: NSObject, UIDocumentPickerDelegate {
    private let picked: ([URL]) -> Void

    init(picked: @escaping ([URL]) -> Void) { self.picked = picked }

    func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
        picked(urls)
    }
}
