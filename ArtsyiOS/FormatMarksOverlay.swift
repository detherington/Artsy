import UIKit
import Combine
import ArtsyEngine

/// A format's marks over the canvas on iPad and iPhone, as the Mac's overlay draws them
/// (see `PageFrameStyle`): a print page's frame, a webtoon's slice marks. Shape layers over
/// the Metal view, their paths built in canvas space and moved into the view whenever the
/// view turns, zooms or pans, or a mark is shown or hidden. Nothing is drawn until the
/// renderer's first frame has fitted the canvas, or the marks would show at one to one,
/// huge, while the screen fades in. Touches pass through to the canvas.
final class FormatMarksOverlay: UIView {
    private weak var viewModel: CanvasViewModel?
    private weak var renderer: CanvasRenderer?
    private let veil = CAShapeLayer()
    private let trim = CAShapeLayer()
    private let safe = CAShapeLayer()
    private let slices = CAShapeLayer()
    private var watch: AnyCancellable?

    init(viewModel: CanvasViewModel, renderer: CanvasRenderer) {
        self.viewModel = viewModel
        self.renderer = renderer
        super.init(frame: .zero)
        isUserInteractionEnabled = false
        backgroundColor = .clear
        // Zoomed in, the marks' paths run far past the view: kept to it, as the canvas is,
        // and off the rail and bar beside it
        clipsToBounds = true
        veil.fillRule = .evenOdd
        veil.fillColor = UIColor(white: 0, alpha: PageFrameStyle.veilAlpha).cgColor
        for line in [trim, safe, slices] {
            line.fillColor = nil
            line.strokeColor = PageFrameStyle.line
            line.lineWidth = 1
        }
        safe.lineDashPattern = PageFrameStyle.dash.map { NSNumber(value: Double($0)) }
        slices.lineDashPattern = PageFrameStyle.sliceDash.map { NSNumber(value: Double($0)) }
        for shape in [veil, trim, safe, slices] { layer.addSublayer(shape) }
        // @Published sends the new value before the property takes it: use what is sent
        watch = viewModel.$transform.combineLatest(viewModel.$guides)
            .sink { [weak self] transform, guides in self?.update(transform: transform, guides: guides) }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func layoutSubviews() {
        super.layoutSubviews()
        guard let viewModel else { return }
        update(transform: viewModel.transform, guides: viewModel.guides)
    }

    private func update(transform: CanvasTransform, guides: CanvasGuides) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        for shape in [veil, trim, safe, slices] { shape.path = nil }
        guard let viewModel, renderer?.hasInitializedTransform == true, bounds.width > 0 else { return }
        // The engine's view space runs y up, as the Mac's; UIKit's runs down
        var toView = transform.affineTransform(viewSize: bounds.size)
            .concatenating(CGAffineTransform(a: 1, b: 0, c: 0, d: -1, tx: 0, ty: bounds.height))
        let canvas = CGRect(origin: .zero, size: viewModel.canvasSize)
        if let page = guides.page, page.isShown {
            let bleed = CGMutablePath()
            bleed.addRect(canvas, transform: toView)
            bleed.addRect(page.trim, transform: toView)
            veil.path = bleed
            trim.path = CGPath(rect: page.trim, transform: &toView)
            safe.path = CGPath(rect: page.safe, transform: &toView)
        }
        if let marks = guides.slices, marks.isShown {
            let cuts = CGMutablePath()
            for y in marks.cuts(canvasHeight: canvas.height) {
                cuts.move(to: CGPoint(x: 0, y: y), transform: toView)
                cuts.addLine(to: CGPoint(x: canvas.width, y: y), transform: toView)
            }
            slices.path = cuts
        }
    }
}
