import CoreGraphics
import Metal

/// What a bucket fill reads to find its region.
public enum FillSource: String, CaseIterable, Identifiable, Sendable {
    /// The layer it fills.
    case layer
    /// The picture as it looks: every visible layer.
    case all
    /// The layer marked as the reference (the inks); the layer it fills if none is.
    case reference

    public var id: String { rawValue }
}

extension CanvasViewModel {
    /// The layer fills read when they read the reference: the one marked, if any.
    public var referenceLayer: Layer? {
        layerStack?.layers.first { $0.isReference }
    }

    /// What a fill on `layer` reads with the fill tool's options: nil for the layer itself.
    func fillSourceTexture(for layer: Layer, renderer: CanvasRenderer) -> MTLTexture? {
        switch fillSource {
        case .layer: return nil
        case .all: return renderer.compositeTexture
        case .reference:
            guard let reference = referenceLayer, reference !== layer else { return nil }
            return reference.texture
        }
    }

    /// A bucket fill at `canvasPoint` on the current layer, with the fill tool's options
    /// (tolerance, what it reads, gaps closed, spread) and the selection: the undo step
    /// saved first, the fill found in the background and applied only if the step still
    /// stands when it lands, then `onLanded`. False, and no step, if the layer is locked
    /// or the point is off the canvas.
    @discardableResult
    public func bucketFill(at canvasPoint: CGPoint, renderer: CanvasRenderer, onLanded: @escaping () -> Void = {}) -> Bool {
        guard let layer = layerStack?.activeLayer, !layer.isLocked else { return false }
        let size = canvasSize
        guard canvasPoint.x >= 0, canvasPoint.x < size.width, canvasPoint.y >= 0, canvasPoint.y < size.height else { return false }
        saveUndoSnapshot(renderer: renderer, description: "Fill", changing: .layer(layer))
        let step = undoManager.lastStepToken
        let started = DispatchTime.now().uptimeNanoseconds
        BucketFill.fillAsync(
            renderer: renderer, layer: layer, reading: fillSourceTexture(for: layer, renderer: renderer),
            canvasPoint: canvasPoint, canvasSize: size, fillColor: currentColor, tolerance: fillTolerance,
            selectionPath: selectionPath, closingGaps: fillCloseGaps, spread: fillSpread,
            keepingAlpha: layer.isAlphaLocked,
            shouldApply: { [weak self, weak layer] in
                // Not if the fill was undone before it finished, or its layer is gone
                guard let self, let layer, self.undoManager.holds(step),
                      self.layerStack?.layers.contains(where: { $0 === layer }) == true else { return false }
                return true
            }
        ) { [weak renderer, weak layer] in
            guard let renderer, let layer else { return }
            DiagnosticsLog.shared.note(.tool, String(format: "fill landed after %.2f s", Double(DispatchTime.now().uptimeNanoseconds - started) / 1e9))
            renderer.updateThumbnail(for: layer)
            // The pixels changed after the undo step noted them: tell the display
            renderer.viewModel?.noteContentChanged()
            onLanded()
        }
        return true
    }
}
