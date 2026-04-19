import AppKit

/// Cursor pool for the Transform tool. Each cursor is built once from an
/// SF Symbol with a black halo stacked behind a white fill so it reads on
/// any background.
enum TransformCursor {

    private static func tinted(_ image: NSImage, color: NSColor) -> NSImage {
        let out = NSImage(size: image.size)
        out.lockFocus()
        image.draw(at: .zero, from: .zero, operation: .sourceOver, fraction: 1.0)
        color.set()
        NSRect(origin: .zero, size: image.size).fill(using: .sourceAtop)
        out.unlockFocus()
        return out
    }

    private static func make(
        _ symbol: String,
        hotSpot: CGPoint = CGPoint(x: 9, y: 9),
        pointSize: CGFloat = 16
    ) -> NSCursor {
        let config = NSImage.SymbolConfiguration(pointSize: pointSize, weight: .semibold)
        guard let base = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
            .withSymbolConfiguration(config) else {
            return NSCursor.crosshair
        }

        let pad: CGFloat = 2
        let sym = base.size
        let canvas = NSSize(width: sym.width + pad * 2, height: sym.height + pad * 2)

        let black = tinted(base, color: .black)
        let white = tinted(base, color: .white)

        let stacked = NSImage(size: canvas)
        stacked.lockFocus()
        for (dx, dy) in [(-1, 0), (1, 0), (0, -1), (0, 1), (-1, -1), (1, 1), (-1, 1), (1, -1)] {
            let r = NSRect(x: pad + CGFloat(dx), y: pad + CGFloat(dy),
                           width: sym.width, height: sym.height)
            black.draw(in: r, from: .zero, operation: .sourceOver, fraction: 1.0)
        }
        white.draw(
            in: NSRect(x: pad, y: pad, width: sym.width, height: sym.height),
            from: .zero, operation: .sourceOver, fraction: 1.0
        )
        stacked.unlockFocus()

        return NSCursor(image: stacked, hotSpot: NSPoint(x: hotSpot.x + pad, y: hotSpot.y + pad))
    }

    static let diagonalNWSE: NSCursor = make("arrow.up.left.and.arrow.down.right")
    static let diagonalNESW: NSCursor = make("arrow.up.right.and.arrow.down.left")
    static let rotate: NSCursor       = make("arrow.triangle.2.circlepath")
    static let move: NSCursor         = NSCursor.openHand
    static let moving: NSCursor       = NSCursor.closedHand

    static func current(for handle: TransformHandle, dragging: Bool = false) -> NSCursor {
        switch handle {
        case .translate:                  return dragging ? moving : move
        case .scaleTL, .scaleBR:           return diagonalNWSE
        case .scaleTR, .scaleBL:           return diagonalNESW
        case .rotate:                      return rotate
        case .none:                        return NSCursor.arrow
        }
    }
}
