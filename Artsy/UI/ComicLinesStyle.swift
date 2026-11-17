import CoreGraphics
import ArtsyEngine

/// How speed or focus lines being laid out are previewed over the canvas, the same on the
/// Mac and on iPad: the lines themselves in the current colour, a little faint so the
/// picture shows through, and the clear area dashed in the drawing guides' violet, with
/// its handles.
enum ComicLinesStyle {
    static let previewAlpha: CGFloat = 0.75
    static let dash: [CGFloat] = [6, 4]

    static func marks(_ lines: ComicLines, canvasSize: CGSize, colour: StrokeColor,
                      toView: CGAffineTransform) -> [RulerStyle.Mark] {
        let shapes = CGMutablePath()
        for line in lines.lines(canvasSize: canvasSize) { shapes.addPath(line.path, transform: toView) }
        let fill = CGColor(colorSpace: CGColorSpace(name: CGColorSpace.displayP3)!,
                           components: [CGFloat(colour.red), CGFloat(colour.green), CGFloat(colour.blue),
                                        CGFloat(colour.alpha) * previewAlpha])
        let clear = lines.clear
        // Kept to the canvas, as the layer they make is
        var canvas = toView
        let inside = CGPath(rect: CGRect(origin: .zero, size: canvasSize), transform: &canvas)
        var marks = [RulerStyle.Mark(path: shapes, stroke: nil, fill: fill, clip: inside)]
        marks.append(RulerStyle.Mark(path: RulerStyle.outline(clear, toView: toView), stroke: RulerStyle.colour(alpha: 0.9),
                                     width: 1.5, dash: dash))
        marks += RulerStyle.handles(rings: [clear.position(of: .axis), clear.position(of: .across)], square: clear.centre,
                                    toView: toView, fill: CGColor(gray: 1, alpha: 1))
        return marks
    }
}
