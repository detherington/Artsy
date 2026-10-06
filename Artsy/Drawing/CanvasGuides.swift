import CoreGraphics

/// Guides over the canvas: a grid, and loose horizontal and vertical lines, which strokes
/// can snap to. Positions are canvas pixels; the view draws them and the pen snaps to
/// them within a few screen points, whatever the zoom.
struct CanvasGuides: Codable, Equatable {
    var showsGrid = false
    /// Canvas pixels between grid lines.
    var gridSpacing: CGFloat = 64
    var snapsToGrid = false
    /// Canvas y of each horizontal guide line.
    var horizontals: [CGFloat] = []
    /// Canvas x of each vertical guide line.
    var verticals: [CGFloat] = []
    var snapsToGuides = true

    /// How close the pen has to come to a line to snap to it, in screen points.
    static let snapDistance: CGFloat = 8

    var isEmpty: Bool { horizontals.isEmpty && verticals.isEmpty }
    var snapsAnything: Bool { (snapsToGuides && !isEmpty) || (snapsToGrid && showsGrid) }

    /// One guide line.
    enum Line: Equatable {
        case horizontal(Int)
        case vertical(Int)
    }

    /// `point` pulled onto whatever line is within reach at `zoom` (screen points per canvas
    /// pixel). A guide holds the coordinate across it and leaves the other free, like a
    /// ruler; the grid holds both. Guides win over the grid.
    func snapped(_ point: CGPoint, zoom: CGFloat) -> CGPoint {
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
    func line(near point: CGPoint, zoom: CGFloat) -> Line? {
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

    mutating func move(_ line: Line, to point: CGPoint) {
        switch line {
        case .horizontal(let i): if horizontals.indices.contains(i) { horizontals[i] = point.y }
        case .vertical(let i): if verticals.indices.contains(i) { verticals[i] = point.x }
        }
    }

    mutating func remove(_ line: Line) {
        switch line {
        case .horizontal(let i): if horizontals.indices.contains(i) { horizontals.remove(at: i) }
        case .vertical(let i): if verticals.indices.contains(i) { verticals.remove(at: i) }
        }
    }
}
