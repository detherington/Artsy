import Foundation
import AppKit

@MainActor
final class UnsplashManager: ObservableObject {
    @Published var query: String = ""
    @Published var results: [UnsplashPhoto] = []
    @Published var isSearching: Bool = false
    @Published var error: String?
    @Published var downloadSize: UnsplashDownloadSize = .regular
    @Published var downloadingPhotoID: String?

    private let service = UnsplashService.shared

    // MARK: - Search

    func search() async {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        isSearching = true
        error = nil
        do {
            let results = try await service.search(query: trimmed)
            self.results = results
        } catch {
            self.error = error.localizedDescription
            self.results = []
        }
        isSearching = false
    }

    // MARK: - Add Photo as Layer

    func addPhotoAsLayer(_ photo: UnsplashPhoto) async {
        guard let appDelegate = NSApp.delegate as? AppDelegate,
              let store = appDelegate.activeStorePublic,
              let layerStack = store.viewModel.layerStack else { return }

        downloadingPhotoID = photo.id
        error = nil
        defer { downloadingPhotoID = nil }

        do {
            let data = try await service.downloadPhoto(photo, size: downloadSize)

            // Save undo snapshot before adding
            store.viewModel.saveUndoSnapshot(renderer: store.canvasView.renderer, description: "Add Stock Image")

            // Create a new layer above the active layer
            let name = "Unsplash: \(photo.user.name)"
            let idx = try layerStack.addLayer(above: layerStack.activeLayerIndex, name: name)
            let layer = layerStack.layers[idx]

            // Fit-to-canvas rasterization + upload
            try store.canvasView.renderer.fillLayerWithImageFitToCanvas(
                imageData: data,
                layer: layer
            )
            store.canvasView.renderer.updateThumbnail(for: layer)
        } catch {
            self.error = error.localizedDescription
        }
    }
}
