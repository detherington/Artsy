import Foundation
import AppKit
import Combine
import SwiftUI

/// The brush being edited in the Brush Studio: a working copy of the canvas's current brush.
///
/// Every change goes straight to the canvas (so the next stroke uses it) and to the
/// library. A built-in brush cannot be changed, so the first change to one makes a copy in
/// the library and switches the canvas to it.
final class BrushStudioModel: ObservableObject {
    @Published private(set) var brush: BrushDescriptor
    @Published private(set) var preview: NSImage?
    @Published private(set) var isBuiltIn: Bool

    private let viewModel: CanvasViewModel
    private let library: BrushLibrary
    private let previewRenderer: BrushPreview?
    private var observation: AnyCancellable?
    private var previewWork: DispatchWorkItem?

    init(viewModel: CanvasViewModel, library: BrushLibrary, previewRenderer: BrushPreview?) {
        self.viewModel = viewModel
        self.library = library
        self.previewRenderer = previewRenderer
        brush = viewModel.currentBrush
        isBuiltIn = !library.isUserBrush(viewModel.currentBrush)

        // Picking another brush in the palette brings it into the studio.
        observation = viewModel.$currentBrush
            .receive(on: RunLoop.main)
            .sink { [weak self] current in
                guard let self = self, current != self.brush else { return }
                self.brush = current
                self.isBuiltIn = !self.library.isUserBrush(current)
                self.schedulePreview()
            }
        schedulePreview()
    }

    /// Change the brush. If it is built in, the change lands on a new copy instead.
    func apply(_ change: (inout BrushDescriptor) -> Void) {
        var edited = brush
        if isBuiltIn {
            do {
                edited = try library.duplicate(brush)
            } catch {
                NSAlert(error: error).runModal()
                return
            }
            isBuiltIn = false
        }
        change(&edited)
        brush = edited
        viewModel.currentBrush = edited
        do {
            try library.save(edited)
        } catch {
            NSAlert(error: error).runModal()
        }
        schedulePreview()
    }

    /// A binding to one field of the brush.
    func binding<Value>(_ keyPath: WritableKeyPath<BrushDescriptor, Value>) -> Binding<Value> {
        Binding(get: { self.brush[keyPath: keyPath] }, set: { value in self.apply { $0[keyPath: keyPath] = value } })
    }

    // MARK: - Rendering kind

    var stampSettings: StampSettings? {
        if case .stamp(let settings) = brush.rendering { return settings }
        return nil
    }

    /// A binding to one field of the stamp settings; does nothing for a ribbon brush.
    func stampBinding<Value>(_ keyPath: WritableKeyPath<StampSettings, Value>, default fallback: Value) -> Binding<Value> {
        Binding(
            get: { self.stampSettings?[keyPath: keyPath] ?? fallback },
            set: { value in
                self.apply { brush in
                    guard case .stamp(var settings) = brush.rendering else { return }
                    settings[keyPath: keyPath] = value
                    brush.rendering = .stamp(settings)
                }
            }
        )
    }

    /// Switch between a ribbon and dabs, keeping whatever settings carry over.
    func setRendersWithDabs(_ dabs: Bool) {
        apply { brush in
            switch (dabs, brush.rendering) {
            case (true, .ribbon):
                brush.rendering = .stamp(StampSettings(spacing: 0.1, flow: 0.5))
            case (false, .stamp):
                brush.rendering = .ribbon(.procedural)
            default:
                break
            }
        }
    }

    // MARK: - Preview

    private func schedulePreview() {
        previewWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.renderPreview() }
        previewWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05, execute: work)
    }

    /// Drawn in the canvas's current colour at its current size.
    private func renderPreview() {
        guard let previewRenderer else { return }
        let color = viewModel.currentColor.alpha > 0 ? viewModel.currentColor : .black
        if let image = previewRenderer.render(brush: brush, color: color, size: viewModel.brushSize) {
            preview = NSImage(cgImage: image, size: previewRenderer.size)
        }
    }

    func renderPreviewNow() {
        previewWork?.cancel()
        renderPreview()
    }
}
