import CoreGraphics

/// How the grid is drawn over the canvas, the same on the Mac and on iPad. It has to show
/// on whatever is under it, white paper, black, or a painting in mid tones, so each line
/// is two strokes: a light one two points wide, under a dark one a point wide. On light
/// paper the light edge disappears and a grey line shows; on dark paper the dark middle
/// disappears and a pale line shows; on mid tones both show.
enum GridStyle {
    /// The dark middle: how much it darkens white paper.
    static let line = CGColor(gray: 0, alpha: 0.22)
    static let lineWidth: CGFloat = 1
    /// The light edge under it: how much it lightens black paper.
    static let edge = CGColor(gray: 1, alpha: 0.22)
    static let edgeWidth: CGFloat = 2
}
