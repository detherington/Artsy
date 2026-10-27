import Foundation
import CoreGraphics
import ImageIO

/// A canvas from a photo, for the start screen's From a photo…: the photo decoded the
/// right way up and no larger than the device allows, a canvas of its size, and the
/// photo as the canvas's first layer, under the empty one that is drawn on.
public enum PhotoCanvas {
    public enum Failure: LocalizedError {
        case undecodable
        case noLayers
        public var errorDescription: String? {
            switch self {
            case .undecodable: return "The photo could not be read"
            case .noLayers: return "The canvas has no layers"
            }
        }
    }

    /// The photo as pixels: turned by its orientation tag, as a phone's portrait shot
    /// needs, and scaled down to fit `maxSide` a side when it is larger; never scaled up.
    public static func image(from data: Data, maxSide: Int) -> CGImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: max(1, maxSide),
            kCGImageSourceShouldCache: false,
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }

    /// The canvas for `image`: its own size, each side at least the smallest canvas.
    public static func canvasSize(for image: CGImage) -> CGSize {
        CGSize(width: max(64, image.width), height: max(64, image.height))
    }

    /// `image` as a layer named `name` just above the background, fit to the canvas, with
    /// the layer above it left as the one to draw on. The index of the photo's layer.
    @discardableResult
    public static func place(_ image: CGImage, named name: String, in viewModel: CanvasViewModel, renderer: CanvasRenderer) throws -> Int {
        guard let layerStack = viewModel.layerStack, !layerStack.layers.isEmpty else { throw Failure.noLayers }
        let drawing = layerStack.activeLayerIndex
        let index = try layerStack.addLayer(above: 0, name: name)
        try renderer.fillLayerFitToCanvas(with: image, layer: layerStack.layers[index])
        renderer.updateThumbnail(for: layerStack.layers[index])
        // The layer that was active moved up one; it stays the one to draw on
        layerStack.activeLayerIndex = min(drawing + 1, layerStack.layers.count - 1)
        viewModel.markDirty()
        return index
    }
}
