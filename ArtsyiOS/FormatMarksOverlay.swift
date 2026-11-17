import UIKit
import Combine
import ArtsyEngine

/// A format's marks over the canvas on iPad and iPhone, as the Mac's overlay draws them
/// (see `PageFrameStyle`): a print page's frame, a webtoon's slice marks; the grid, the
/// guide lines, perspective (see `PerspectiveStyle`), the ruler and the ellipse template (see
/// `RulerStyle`), with their handles while they are being moved; and the balloon the Letter tool holds, with its handles. Shape layers over
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
    /// The grid: a light edge under a dark line, so it shows on any paper (see `GridStyle`).
    private let gridEdge = CAShapeLayer()
    private let grid = CAShapeLayer()
    private let guideLines = CAShapeLayer()
    /// Perspective's rays, horizon and handles, made again whenever they change.
    private let perspective = CALayer()
    /// The ruler and the ellipse template with their handles, made again whenever they change.
    private let rulers = CALayer()
    /// The balloon the Letter tool holds: a dashed box and its handles.
    private let balloonBox = CAShapeLayer()
    private let balloonHandles = CAShapeLayer()
    private var watch: AnyCancellable?
    private var balloonWatch: AnyCancellable?

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
        balloonBox.fillColor = nil
        balloonBox.strokeColor = BalloonSelectionStyle.colour
        balloonBox.lineWidth = 1
        balloonBox.lineDashPattern = BalloonSelectionStyle.dash.map { NSNumber(value: Double($0)) }
        balloonHandles.fillColor = UIColor.white.cgColor
        balloonHandles.strokeColor = BalloonSelectionStyle.colour
        balloonHandles.lineWidth = 1.5
        // As the Mac's: the grid light under dark, the guide lines teal
        gridEdge.fillColor = nil
        gridEdge.strokeColor = GridStyle.edge
        gridEdge.lineWidth = GridStyle.edgeWidth
        grid.fillColor = nil
        grid.strokeColor = GridStyle.line
        grid.lineWidth = GridStyle.lineWidth
        guideLines.fillColor = nil
        guideLines.strokeColor = UIColor.systemTeal.withAlphaComponent(0.85).cgColor
        guideLines.lineWidth = 1
        for shape in [gridEdge, grid, guideLines, veil, trim, safe, slices, perspective, rulers, balloonBox, balloonHandles] { layer.addSublayer(shape) }
        // @Published sends the new value before the property takes it: use what is sent
        watch = Publishers.CombineLatest4(viewModel.$transform, viewModel.$guides, viewModel.$editingGuide, viewModel.$comicLines)
            .sink { [weak self] transform, guides, editing, comicLines in
                self?.update(transform: transform, guides: guides, editing: editing, comicLines: comicLines)
            }
        // A balloon's own changes reach its layer before the count of them is sent
        balloonWatch = Publishers.CombineLatest4(viewModel.$transform, viewModel.$selectedBalloonID,
                                                 viewModel.$letteringRevision, viewModel.$currentTool)
            .sink { [weak self] transform, id, _, tool in self?.updateBalloon(transform: transform, id: id, tool: tool) }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func layoutSubviews() {
        super.layoutSubviews()
        guard let viewModel else { return }
        update(transform: viewModel.transform, guides: viewModel.guides, editing: viewModel.editingGuide, comicLines: viewModel.comicLines)
        updateBalloon(transform: viewModel.transform, id: viewModel.selectedBalloonID, tool: viewModel.currentTool)
    }

    /// Canvas space, y up, into this view's, y down.
    private func toView(_ transform: CanvasTransform) -> CGAffineTransform {
        transform.affineTransform(viewSize: bounds.size)
            .concatenating(CGAffineTransform(a: 1, b: 0, c: 0, d: -1, tx: 0, ty: bounds.height))
    }

    private func updateBalloon(transform: CanvasTransform, id: UUID?, tool: ToolType) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        balloonBox.path = nil
        balloonHandles.path = nil
        guard tool == .letter, let id, let viewModel, let balloon = viewModel.balloons.first(where: { $0.id == id }),
              renderer?.hasInitializedTransform == true, bounds.width > 0 else { return }
        var toView = toView(transform)
        let layout = BalloonLayout(balloon)
        balloonBox.path = CGPath(rect: layout.bounds, transform: &toView)
        let handles = CGMutablePath()
        let r = BalloonSelectionStyle.handleRadius
        if let tail = layout.tailHandle {
            let p = tail.applying(toView)
            handles.addEllipse(in: CGRect(x: p.x - r, y: p.y - r, width: 2 * r, height: 2 * r))
        }
        if let tail = layout.tailHandle, balloon.tailPinned {
            // A pinned tip: a ring inside its handle
            let p = tail.applying(toView), d = r * 0.45
            handles.addEllipse(in: CGRect(x: p.x - d, y: p.y - d, width: 2 * d, height: 2 * d))
        }
        if let base = layout.baseHandle {
            // A diamond at the end of the tail's base, which sets how wide it is
            let p = base.applying(toView), d = r * 1.2
            handles.addLines(between: [CGPoint(x: p.x, y: p.y - d), CGPoint(x: p.x + d, y: p.y), CGPoint(x: p.x, y: p.y + d),
                                       CGPoint(x: p.x - d, y: p.y)])
            handles.closeSubpath()
        }
        let w = layout.widthHandle.applying(toView)
        handles.addRect(CGRect(x: w.x - r, y: w.y - r, width: 2 * r, height: 2 * r))
        balloonHandles.path = handles
    }

    private func update(transform: CanvasTransform, guides: CanvasGuides, editing: DrawingGuide?, comicLines: ComicLines?) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        for shape in [veil, trim, safe, slices, gridEdge, grid, guideLines] { shape.path = nil }
        perspective.sublayers = nil
        rulers.sublayers = nil
        guard let viewModel, renderer?.hasInitializedTransform == true, bounds.width > 0 else { return }
        // The engine's view space runs y up, as the Mac's; UIKit's runs down
        var toView = toView(transform)
        let canvas = CGRect(origin: .zero, size: viewModel.canvasSize)
        if guides.showsGrid, guides.gridSpacing > 0 {
            // Zoomed out, every second, fourth… line, so the grid never turns to mush
            var step = guides.gridSpacing
            while step * transform.scale < 8 { step *= 2 }
            var segments: [(CGPoint, CGPoint)] = []
            var x = step
            while x < canvas.width { segments.append((CGPoint(x: x, y: 0), CGPoint(x: x, y: canvas.height))); x += step }
            var y = step
            while y < canvas.height { segments.append((CGPoint(x: 0, y: y), CGPoint(x: canvas.width, y: y))); y += step }
            grid.path = PerspectiveStyle.path(segments, toView: toView)
            gridEdge.path = grid.path
        }
        let lines = guides.verticals.map { (CGPoint(x: $0, y: 0), CGPoint(x: $0, y: canvas.height)) }
            + guides.horizontals.map { (CGPoint(x: 0, y: $0), CGPoint(x: canvas.width, y: $0)) }
        if !lines.isEmpty { guideLines.path = PerspectiveStyle.path(lines, toView: toView) }
        if let shown = guides.perspective, shown.isShown {
            addPerspective(shown, canvas: canvas, editing: editing == .perspective, toView: toView)
        }
        var marks = RulerStyle.marks(ruler: guides.ruler, ellipse: guides.ellipse, editing: editing, toView: toView)
        if let comicLines {
            marks += ComicLinesStyle.marks(comicLines, canvasSize: viewModel.canvasSize, colour: viewModel.currentColor, toView: toView)
        }
        for mark in marks {
            let shape = CAShapeLayer()
            shape.path = mark.path
            shape.strokeColor = mark.stroke
            shape.fillColor = mark.fill
            shape.lineWidth = mark.width
            shape.lineDashPattern = mark.dash?.map { NSNumber(value: Double($0)) }
            if let clip = mark.clip {
                shape.frame = CGRect(origin: .zero, size: bounds.size)
                let mask = CAShapeLayer()
                mask.frame = shape.bounds
                mask.path = clip
                shape.mask = mask
            }
            rulers.addSublayer(shape)
        }
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

    /// Perspective, as the Mac's overlay draws it: each point's rays in its colour, the
    /// horizon in amber, and while editing a ring at each point and a square at the
    /// horizon's middle.
    private func addPerspective(_ guide: PerspectiveGuide, canvas: CGRect, editing: Bool, toView: CGAffineTransform) {
        func shape(_ path: CGPath, stroke: CGColor, width: CGFloat, fill: CGColor? = nil) {
            let layer = CAShapeLayer()
            layer.path = path
            layer.strokeColor = stroke
            layer.fillColor = fill
            layer.lineWidth = width
            perspective.addSublayer(layer)
        }
        for index in guide.points.indices {
            shape(PerspectiveStyle.path(guide.rays(from: index, across: canvas, count: PerspectiveStyle.rays), toView: toView),
                  stroke: PerspectiveStyle.colour(index, alpha: PerspectiveStyle.rayAlpha(editing: editing)), width: 1)
        }
        if let horizon = guide.horizonLine(across: PerspectiveStyle.horizonRect(guide, canvas: canvas, editing: editing)) {
            shape(PerspectiveStyle.path([horizon], toView: toView), stroke: PerspectiveStyle.horizon, width: 1.5)
        }
        guard editing else { return }
        let handles = PerspectiveStyle.handles(guide, toView: toView)
        for (index, handle) in handles.points.enumerated() {
            shape(handle, stroke: PerspectiveStyle.colour(index), width: 2, fill: UIColor.white.cgColor)
        }
        if let horizon = handles.horizon {
            shape(horizon, stroke: PerspectiveStyle.horizon, width: 2, fill: UIColor.white.cgColor)
        }
    }
}
