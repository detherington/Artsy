import Foundation
import CoreGraphics

/// Draws mirrored copies of each stroke in real time.
///
/// - `off`:            no mirroring (single stroke, default)
/// - `horizontal`:     mirror across the canvas vertical center line (two strokes)
/// - `vertical`:       mirror across the canvas horizontal center line (two strokes)
/// - `quad`:           mirror across both axes (four strokes)
/// - `radial(N)`:      N-fold rotational symmetry around canvas center (N ≥ 2 strokes)
enum SymmetryMode: Equatable, Hashable {
    case off
    case horizontal
    case vertical
    case quad
    case radial(Int)

    var isOn: Bool {
        if case .off = self { return false }
        return true
    }

    var displayName: String {
        switch self {
        case .off: return "Off"
        case .horizontal: return "Horizontal"
        case .vertical: return "Vertical"
        case .quad: return "Quad"
        case .radial(let n): return "Radial ×\(n)"
        }
    }
}

/// Transform helpers that emit multiple mirror-copies of a point array.
/// Canvas coordinates are Y-up with origin at bottom-left and range
/// [0, canvasSize.width] × [0, canvasSize.height]. All mirrors reflect/
/// rotate around the canvas center `(W/2, H/2)`.
enum SymmetryTransform {

    /// Returns an array of transforms as `(CGPoint) -> CGPoint` closures, INCLUDING
    /// the identity transform as the first entry. Callers apply each transform to
    /// their point array to produce one mirror-copy per transform.
    static func transforms(mode: SymmetryMode, canvasSize: CGSize) -> [(CGPoint) -> CGPoint] {
        let cx = canvasSize.width / 2
        let cy = canvasSize.height / 2

        switch mode {
        case .off:
            return [{ $0 }]

        case .horizontal:
            return [
                { $0 },
                { CGPoint(x: canvasSize.width - $0.x, y: $0.y) }
            ]

        case .vertical:
            return [
                { $0 },
                { CGPoint(x: $0.x, y: canvasSize.height - $0.y) }
            ]

        case .quad:
            return [
                { $0 },
                { CGPoint(x: canvasSize.width - $0.x, y: $0.y) },
                { CGPoint(x: $0.x, y: canvasSize.height - $0.y) },
                { CGPoint(x: canvasSize.width - $0.x, y: canvasSize.height - $0.y) }
            ]

        case .radial(let n):
            let count = max(2, n)
            return (0..<count).map { k in
                let angle = (CGFloat(k) * 2 * .pi) / CGFloat(count)
                let sinA = sin(angle)
                let cosA = cos(angle)
                return { p in
                    let dx = p.x - cx
                    let dy = p.y - cy
                    return CGPoint(x: dx * cosA - dy * sinA + cx,
                                   y: dx * sinA + dy * cosA + cy)
                }
            }
        }
    }
}
