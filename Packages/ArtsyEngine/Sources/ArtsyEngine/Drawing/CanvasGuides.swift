import CoreGraphics

/// Guides over the canvas: a grid, and loose horizontal and vertical lines, which strokes
/// can snap to. Positions are canvas pixels; the view draws them and the pen snaps to
/// them within a few screen points, whatever the zoom.
public struct CanvasGuides: Codable, Equatable {
    public var showsGrid = false
    /// Canvas pixels between grid lines.
    public var gridSpacing: CGFloat = 64
    public var snapsToGrid = false
    /// Canvas y of each horizontal guide line.
    public var horizontals: [CGFloat] = []
    /// Canvas x of each vertical guide line.
    public var verticals: [CGFloat] = []
    public var snapsToGuides = true
    /// The printed page's frame, for a canvas made at a print format; nil for any other.
    /// Optional so that a document from before it decodes with none.
    public var page: PageFrame?
    /// Where a strip for the screen is cut for upload, for a canvas made as one; nil for
    /// any other. Optional for the same reason.
    public var slices: SliceMarks?

    /// How close the pen has to come to a line to snap to it, in screen points.
    public static let snapDistance: CGFloat = 8

    public var isEmpty: Bool { horizontals.isEmpty && verticals.isEmpty }
    public var snapsAnything: Bool { (snapsToGuides && !isEmpty) || (snapsToGrid && showsGrid) }

    /// One guide line.
    public enum Line: Equatable {
        case horizontal(Int)
        case vertical(Int)
    }

    /// `point` pulled onto whatever line is within reach at `zoom` (screen points per canvas
    /// pixel). A guide holds the coordinate across it and leaves the other free, like a
    /// ruler; the grid holds both. Guides win over the grid.
    public func snapped(_ point: CGPoint, zoom: CGFloat) -> CGPoint {
        let reach = Self.snapDistance / max(zoom, 0.01)
        var result = point
        var xHeld = false, yHeld = false
        if snapsToGuides {
            if let x = verticals.min(by: { abs($0 - point.x) < abs($1 - point.x) }), abs(x - point.x) <= reach {
                result.x = x
                xHeld = true
            }
            if let y = horizontals.min(by: { abs($0 - point.y) < abs($1 - point.y) }), abs(y - point.y) <= reach {
                result.y = y
                yHeld = true
            }
        }
        if snapsToGrid, showsGrid, gridSpacing > 0 {
            let gx = (point.x / gridSpacing).rounded() * gridSpacing
            let gy = (point.y / gridSpacing).rounded() * gridSpacing
            if !xHeld, abs(gx - point.x) <= reach { result.x = gx }
            if !yHeld, abs(gy - point.y) <= reach { result.y = gy }
        }
        return result
    }

    /// The guide within reach of `point`, for picking one up.
    public func line(near point: CGPoint, zoom: CGFloat) -> Line? {
        let reach = Self.snapDistance / max(zoom, 0.01)
        var best: (line: Line, distance: CGFloat)?
        for (i, x) in verticals.enumerated() where abs(x - point.x) <= reach {
            if best == nil || abs(x - point.x) < best!.distance { best = (.vertical(i), abs(x - point.x)) }
        }
        for (i, y) in horizontals.enumerated() where abs(y - point.y) <= reach {
            if best == nil || abs(y - point.y) < best!.distance { best = (.horizontal(i), abs(y - point.y)) }
        }
        return best?.line
    }

    public mutating func move(_ line: Line, to point: CGPoint) {
        switch line {
        case .horizontal(let i): if horizontals.indices.contains(i) { horizontals[i] = point.y }
        case .vertical(let i): if verticals.indices.contains(i) { verticals[i] = point.x }
        }
    }

    public mutating func remove(_ line: Line) {
        switch line {
        case .horizontal(let i): if horizontals.indices.contains(i) { horizontals.remove(at: i) }
        case .vertical(let i): if verticals.indices.contains(i) { verticals.remove(at: i) }
        }
    }

    public init(gridSpacing: CGFloat = 64, horizontals: [CGFloat] = [], verticals: [CGFloat] = []) {
        self.gridSpacing = gridSpacing
        self.horizontals = horizontals
        self.verticals = verticals
    }
}

/// A printed page's frame on a canvas that holds the page with its bleed: the trim,
/// where the printer cuts, and the safe area inside it, where lettering and anything
/// that must not be lost belongs. The canvas past the trim is the bleed. Canvas pixels;
/// drawn over the canvas, never into the picture, and not snapped to.
public struct PageFrame: Codable, Equatable {
    public var trim: CGRect
    public var safe: CGRect
    public var isShown = true

    /// The frame of a page whose bleed is the whole canvas: the trim `trimInset` pixels in
    /// from each edge, the safe area `safeInset`.
    public init(canvasSize: CGSize, trimInset: CGFloat, safeInset: CGFloat) {
        let canvas = CGRect(origin: .zero, size: canvasSize)
        trim = canvas.insetBy(dx: trimInset, dy: trimInset)
        safe = canvas.insetBy(dx: safeInset, dy: safeInset)
    }

    /// The frame of a page whose bleed is the whole canvas: a trim of `trim` and a safe
    /// area of `safe`, both in the middle of it. For a format whose safe area is not the
    /// same distance in on every side, as a manga page's inner frame is not.
    public init(canvasSize: CGSize, trim: CGSize, safe: CGSize) {
        func centred(_ size: CGSize) -> CGRect {
            CGRect(x: (canvasSize.width - size.width) / 2, y: (canvasSize.height - size.height) / 2,
                   width: size.width, height: size.height)
        }
        self.trim = centred(trim)
        self.safe = centred(safe)
    }
}

/// Where a strip for the screen, a webtoon, is cut into the pieces a site takes: every
/// `height` canvas pixels from the top, each piece then scaled to `exportWidth` across.
/// Drawn over the canvas as dashed lines across it, never into the picture; the sliced
/// export cuts at them.
public struct SliceMarks: Codable, Equatable {
    /// Canvas pixels from one cut to the next.
    public var height: CGFloat
    /// The width each piece is exported at.
    public var exportWidth: Int
    public var isShown = true

    public init(height: CGFloat, exportWidth: Int) {
        self.height = height
        self.exportWidth = exportWidth
    }

    /// WEBTOON's: pieces up to 800 × 1,280, so a cut every 1.6 widths of a canvas
    /// `canvasWidth` across, scaled to 800.
    public static func webtoon(canvasWidth: CGFloat) -> SliceMarks {
        SliceMarks(height: (canvasWidth * 1280 / 800).rounded(), exportWidth: 800)
    }

    /// The pieces, top first, as rows of the picture: `y` from the top, as an image's rows
    /// run; the last is whatever is left.
    public func pieces(canvasHeight: CGFloat) -> [ClosedRange<CGFloat>] {
        guard height > 0 else { return [0...canvasHeight] }
        var pieces: [ClosedRange<CGFloat>] = []
        var top: CGFloat = 0
        while top < canvasHeight {
            pieces.append(top...min(top + height, canvasHeight))
            top += height
        }
        return pieces
    }

    /// The canvas y of each cut between pieces, canvas y running up as it does.
    public func cuts(canvasHeight: CGFloat) -> [CGFloat] {
        pieces(canvasHeight: canvasHeight).dropLast().map { canvasHeight - $0.upperBound }
    }
}
