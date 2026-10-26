import AppKit
import ArtsyEngine

extension CanvasDocument {
    /// Open the document at `url` into a canvas view of its own: the engine reads the
    /// document and fills the layers; the view and its renderer are the Mac's.
    static func open(from url: URL, metalContext: MetalContext) throws -> (viewModel: CanvasViewModel, canvasView: CanvasView) {
        let doc = try read(from: url)
        let viewModel = CanvasViewModel(canvasSize: canvasSize(of: doc))
        let canvasView = CanvasView(frame: NSRect(x: 0, y: 0, width: 800, height: 600), device: metalContext.device)
        try canvasView.configure(context: metalContext, viewModel: viewModel)
        try populate(viewModel, from: url, document: doc, metalContext: metalContext)
        return (viewModel, canvasView)
    }
}
