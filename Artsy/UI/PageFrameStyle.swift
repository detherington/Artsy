import CoreGraphics

/// How a print page's frame is drawn over the canvas, the same on the Mac and on iPad:
/// the bleed past the trim under a light veil, the trim a solid line and the safe area a
/// dashed one, in a blue that reads over white paper and dark paint alike.
enum PageFrameStyle {
    static let line = CGColor(srgbRed: 0.2, green: 0.5, blue: 1, alpha: 0.85)
    static let veilAlpha: CGFloat = 0.12
    /// The safe area's dashes, in points.
    static let dash: [CGFloat] = [6, 4]
}
