import CoreGraphics
import Foundation

/// A comic page's panels: rows from the top, each with a share of the height and its
/// panels' shares of the width, left to right. Laid out inside an area of the page (its
/// safe area) with gutters between, and drawn as borders on a layer of their own, which
/// the artist then draws under, over or erases as they like.
public struct PanelLayout: Identifiable, Equatable {
    public struct Row: Equatable {
        /// This row's share of the height, against the other rows'.
        public var height: CGFloat
        /// Each panel's share of the width, left to right.
        public var panels: [CGFloat]
    }

    public let name: String
    public let rows: [Row]
    public var id: String { name }

    public init(_ name: String, _ rows: [(height: CGFloat, panels: [CGFloat])]) {
        self.name = name
        self.rows = rows.map { Row(height: $0.height, panels: $0.panels) }
    }

    /// The layouts offered: the grids a page is most often cut into, and a few that break
    /// them for a big moment.
    public static let all: [PanelLayout] = [
        PanelLayout("Splash", [(1, [1])]),
        PanelLayout("Two tiers", [(1, [1]), (1, [1])]),
        PanelLayout("Three tiers", [(1, [1]), (1, [1]), (1, [1])]),
        PanelLayout("Four", [(1, [1, 1]), (1, [1, 1])]),
        PanelLayout("Six", [(1, [1, 1]), (1, [1, 1]), (1, [1, 1])]),
        PanelLayout("Nine", [(1, [1, 1, 1]), (1, [1, 1, 1]), (1, [1, 1, 1])]),
        PanelLayout("Two one two", [(1, [1, 1]), (1, [1]), (1, [1, 1])]),
        PanelLayout("Wide top", [(1.5, [1]), (1, [1, 1, 1])]),
        PanelLayout("Stagger", [(1, [2, 1]), (1, [1, 1, 1]), (1, [1, 2])]),
    ]

    /// The panels inside `area`, `gutter` apart: top row first, each row left to right.
    /// Rectangles with y running down, as on a page.
    public func panels(in area: CGRect, gutter: CGFloat) -> [CGRect] {
        let totalHeight = rows.map(\.height).reduce(0, +)
        let freeHeight = area.height - gutter * CGFloat(max(0, rows.count - 1))
        guard totalHeight > 0, freeHeight > 0 else { return [] }
        var result: [CGRect] = []
        var y = area.minY
        for row in rows {
            let height = freeHeight * row.height / totalHeight
            let totalWidth = row.panels.reduce(0, +)
            let freeWidth = area.width - gutter * CGFloat(max(0, row.panels.count - 1))
            var x = area.minX
            for share in row.panels where totalWidth > 0 {
                let width = freeWidth * share / totalWidth
                result.append(CGRect(x: x, y: y, width: width, height: height))
                x += width + gutter
            }
            y += height + gutter
        }
        return result
    }

    /// Where the panels go on a canvas, with y running down: inside the page's safe area if
    /// it has one, or else inside a margin of a twentieth of the canvas's shorter side.
    public static func area(canvasSize: CGSize, page: PageFrame?) -> CGRect {
        if let safe = page?.safe {
            // The frame is in canvas space, y up
            return CGRect(x: safe.minX, y: canvasSize.height - safe.maxY, width: safe.width, height: safe.height)
        }
        let margin = (min(canvasSize.width, canvasSize.height) / 20).rounded()
        return CGRect(origin: .zero, size: canvasSize).insetBy(dx: margin, dy: margin)
    }

    /// The borders of `panels` (y running down), `border` wide just inside each one, in
    /// black, on a transparent image the canvas's size, upright.
    public static func borderImage(panels: [CGRect], canvasSize: CGSize, border: CGFloat) -> CGImage? {
        let width = Int(canvasSize.width), height = Int(canvasSize.height)
        guard width > 0, height > 0, let colorSpace = CGColorSpace(name: CGColorSpace.displayP3),
              let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                      space: colorSpace, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        // The panels run down from the top; the context's y runs up
        context.translateBy(x: 0, y: CGFloat(height))
        context.scaleBy(x: 1, y: -1)
        context.setStrokeColor(CGColor(colorSpace: colorSpace, components: [0, 0, 0, 1]) ?? CGColor(gray: 0, alpha: 1))
        context.setLineWidth(border)
        context.setLineJoin(.miter)
        for panel in panels where panel.width > border && panel.height > border {
            context.stroke(panel.insetBy(dx: border / 2, dy: border / 2))
        }
        return context.makeImage()
    }

    public enum Failure: LocalizedError {
        case noCanvas
        case couldNotDraw
        public var errorDescription: String? {
            switch self {
            case .noCanvas: return "There is no canvas to add panels to"
            case .couldNotDraw: return "The panels could not be drawn"
            }
        }
    }

    /// This layout's borders as a new layer, "Panels", above the current one, inside the
    /// page's safe area (or the canvas's margin): one step to undo.
    @discardableResult
    public func addLayer(to viewModel: CanvasViewModel, renderer: CanvasRenderer,
                         gutter: PanelGutter, border: PanelBorder) throws -> Layer {
        guard let stack = viewModel.layerStack else { throw Failure.noCanvas }
        let size = viewModel.canvasSize
        let area = Self.area(canvasSize: size, page: viewModel.guides.page)
        let panels = panels(in: area, gutter: gutter.width(across: area.width))
        guard let image = Self.borderImage(panels: panels, canvasSize: size, border: border.width(across: area.width)) else {
            throw Failure.couldNotDraw
        }
        // Adding a layer is a step to undo; nothing already there changes
        viewModel.saveUndoSnapshot(renderer: renderer, description: "Add Panels", changing: .nothing)
        let step = viewModel.undoManager.lastStepToken
        do {
            let index = try stack.addLayer(above: stack.activeLayerIndex, name: "Panels")
            let layer = stack.layers[index]
            try renderer.fillLayerFitToCanvas(with: image, layer: layer)
            renderer.updateThumbnail(for: layer)
            viewModel.markDirty()
            return layer
        } catch {
            viewModel.undoManager.popLastSnapshot(if: step)
            throw error
        }
    }
}

/// How far apart panels sit: a share of the width they fill, so a page looks the same at
/// any resolution. Medium on a US comic page's safe area is about ⅛ inch.
public enum PanelGutter: String, CaseIterable, Identifiable {
    case narrow, medium, wide
    public var id: String { rawValue }
    public var share: CGFloat {
        switch self {
        case .narrow: return 0.012
        case .medium: return 0.02
        case .wide: return 0.032
        }
    }
    public func width(across areaWidth: CGFloat) -> CGFloat { (areaWidth * share).rounded() }
}

/// How heavy panel borders are, as a share of the width the panels fill. Medium on a US
/// comic page is about 2 points at print size.
public enum PanelBorder: String, CaseIterable, Identifiable {
    case thin, medium, bold
    public var id: String { rawValue }
    public var share: CGFloat {
        switch self {
        case .thin: return 0.0025
        case .medium: return 0.004
        case .bold: return 0.007
        }
    }
    public func width(across areaWidth: CGFloat) -> CGFloat { max(1, (areaWidth * share).rounded()) }
}
