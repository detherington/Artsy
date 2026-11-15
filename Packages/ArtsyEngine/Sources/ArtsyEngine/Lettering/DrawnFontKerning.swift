import CoreGraphics
import Foundation

/// Kerning suggested from a drawn font's outlines: how much closer two letters should sit for
/// the space between them to look like the space between two straight letters (H and H).
/// Across the rows where both have ink, the gap between the first's right edge and the
/// second's left edge is averaged, open rows counting for no more than three times the
/// even gap so the hollow under a T does not swallow the pair, and the pair is brought that
/// much toward the even gap, never so close that the letters touch.
public enum DrawnFontKerning {
    /// Pairs that want kerning in most hands, capitals and figures with the punctuation
    /// beside them; the studio suggests those whose letters are drawn.
    public static let commonPairs: [String] = [
        "AV", "AW", "AY", "AT", "AC", "AG", "AO", "AQ", "AU", "A'", "A\"",
        "FA", "F.", "F,", "LT", "LV", "LW", "LY", "L'", "L\"", "PA", "P.", "P,",
        "TA", "TO", "TC", "TG", "T.", "T,", "TJ", "VA", "VO", "VC", "VG", "V.", "V,",
        "WA", "WO", "WC", "W.", "W,", "YA", "YO", "YC", "YG", "Y.", "Y,", "RV", "RW", "RY", "RT",
        "OA", "OV", "OW", "OY", "OT", "OX", "DA", "DV", "DW", "DY", "QV", "KO", "KC", "XO",
        "CA", "GT", "UA", "JA", "BV", "BY", "SV", "SY", "LO", "LU", "\"A", "'A", "17", "71", "74",
    ]

    /// How far either side of a letter's ink its rows are read, in font units.
    static let rowStep: CGFloat = 10

    /// A glyph's ink as rows: for each row from the descender to above the capitals, the
    /// leftmost and rightmost ink in it, or nil where it has none.
    struct Profile {
        var left: [CGFloat?]
        var right: [CGFloat?]
        var xMin: CGFloat
        var xMax: CGFloat
    }

    static let rows: [CGFloat] = Array(stride(from: DrawnFont.descender - 40, through: DrawnFont.capHeight + 80, by: rowStep))

    static func profile(of contours: [GlyphOutline.Contour]) -> Profile? {
        let polygons = contours.map { $0.map { CGPoint(x: $0.x, y: $0.y) } }
        let xs = polygons.flatMap { $0.map(\.x) }
        guard let xMin = xs.min(), let xMax = xs.max() else { return nil }
        var left: [CGFloat?] = [], right: [CGFloat?] = []
        for y in rows {
            // Where the row crosses the outlines; ink lies between the crossings
            var crossings: [CGFloat] = []
            for polygon in polygons {
                var j = polygon.count - 1
                for i in polygon.indices {
                    let a = polygon[i], b = polygon[j]
                    if (a.y > y) != (b.y > y) {
                        crossings.append(a.x + (y - a.y) / (b.y - a.y) * (b.x - a.x))
                    }
                    j = i
                }
            }
            left.append(crossings.min())
            right.append(crossings.max())
        }
        return Profile(left: left, right: right, xMin: xMin, xMax: xMax)
    }

    /// The kerning for `left` then `right`, set `spacing` either side of their ink, from their
    /// clean outlines; rounded to fives, and 0 where they share no rows.
    public static func suggest(left: [GlyphOutline.Contour], right: [GlyphOutline.Contour], spacing: Int) -> Int {
        guard let a = profile(of: left), let b = profile(of: right) else { return 0 }
        let even = CGFloat(2 * spacing)
        // Each glyph set as the font sets it: its ink `spacing` from its left edge
        let advanceA = a.xMax - a.xMin + CGFloat(2 * spacing)
        var gaps: [CGFloat] = []
        for i in rows.indices {
            guard let edgeA = a.right[i], let edgeB = b.left[i] else { continue }
            let gap = (advanceA - (edgeA - a.xMin + CGFloat(spacing))) + (edgeB - b.xMin + CGFloat(spacing))
            gaps.append(gap)
        }
        guard gaps.count >= 3, let closest = gaps.min() else { return 0 }
        let ceiling = max(even * 3, 60)
        let average = gaps.map { min($0, ceiling) }.reduce(0, +) / CGFloat(gaps.count)
        var kern = (even - average) * 0.6
        // Never closer than the letters' own minimum room
        let floor = max(CGFloat(spacing) * 0.6, 12)
        kern = max(kern, floor - closest)
        kern = min(max(kern, -320), 120)
        return Int((kern / 5).rounded()) * 5
    }
}
