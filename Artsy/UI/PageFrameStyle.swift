import CoreGraphics

/// How a format's marks are drawn over the canvas, the same on the Mac and on iPad: a
/// print page's bleed past the trim under a light veil, the trim a solid line and the safe
/// area a dashed one; a webtoon's slice marks in longer dashes; all in a blue that reads
/// over white paper and dark paint alike.
enum PageFrameStyle {
    static let line = CGColor(srgbRed: 0.2, green: 0.5, blue: 1, alpha: 0.85)
    static let veilAlpha: CGFloat = 0.12
    /// The safe area's dashes, in points.
    static let dash: [CGFloat] = [6, 4]
    /// A webtoon's slice marks, longer dashes across the strip, in the same blue.
    static let sliceDash: [CGFloat] = [14, 6]
}
