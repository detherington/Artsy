import AppKit

/// Cursor pool for each drawing tool. Each NSCursor is built once at startup
/// from an SF Symbol (or asset image) rendered into an NSImage. A thick
/// black halo is stacked underneath a white fill so the cursor reads on
/// canvases of any color.
enum ToolCursor {

    // MARK: - Tinted image builders

    /// Tint an existing image with a solid color by drawing it then filling
    /// the rect with `.sourceAtop` (only where the image has non-zero alpha).
    /// Works for both SF Symbols (after sizing) and template assets.
    private static func tinted(_ image: NSImage, color: NSColor) -> NSImage {
        let out = NSImage(size: image.size)
        out.lockFocus()
        image.draw(at: .zero, from: .zero, operation: .sourceOver, fraction: 1.0)
        color.set()
        NSRect(origin: .zero, size: image.size).fill(using: .sourceAtop)
        out.unlockFocus()
        return out
    }

    /// Compose a cursor image by stacking the tinted template at 8 one-pixel
    /// offsets in black for a halo, then the white version on top. Returns
    /// the final NSCursor with the hotspot offset to account for the halo
    /// padding.
    private static func cursor(from image: NSImage, hotSpot: CGPoint) -> NSCursor {
        let pad: CGFloat = 2
        let sym = image.size
        let canvas = NSSize(width: sym.width + pad * 2, height: sym.height + pad * 2)

        let black = tinted(image, color: .black)
        let white = tinted(image, color: .white)

        let stacked = NSImage(size: canvas)
        stacked.lockFocus()
        // 8-way offset halo
        for (dx, dy) in [(-1, 0), (1, 0), (0, -1), (0, 1), (-1, -1), (1, 1), (-1, 1), (1, -1)] {
            let r = NSRect(x: pad + CGFloat(dx), y: pad + CGFloat(dy),
                           width: sym.width, height: sym.height)
            black.draw(in: r, from: .zero, operation: .sourceOver, fraction: 1.0)
        }
        // White symbol on top
        white.draw(
            in: NSRect(x: pad, y: pad, width: sym.width, height: sym.height),
            from: .zero, operation: .sourceOver, fraction: 1.0
        )
        stacked.unlockFocus()

        return NSCursor(image: stacked, hotSpot: NSPoint(x: hotSpot.x + pad, y: hotSpot.y + pad))
    }

    /// Build a cursor from an SF Symbol name.
    private static func fromSymbol(
        _ name: String,
        hotSpot: CGPoint,
        pointSize: CGFloat = 16
    ) -> NSCursor {
        let config = NSImage.SymbolConfiguration(pointSize: pointSize, weight: .semibold)
        guard let base = NSImage(systemSymbolName: name, accessibilityDescription: nil)?
            .withSymbolConfiguration(config) else {
            return NSCursor.crosshair
        }
        return cursor(from: base, hotSpot: hotSpot)
    }

    /// Build a cursor from an asset-catalog template image.
    private static func fromAsset(
        _ name: String,
        hotSpot: CGPoint,
        size: CGFloat = 22
    ) -> NSCursor {
        guard let template = NSImage(named: name) else { return NSCursor.crosshair }
        let sized = NSImage(size: NSSize(width: size, height: size))
        sized.lockFocus()
        template.draw(
            in: NSRect(x: 0, y: 0, width: size, height: size),
            from: .zero, operation: .sourceOver, fraction: 1.0
        )
        sized.unlockFocus()
        return cursor(from: sized, hotSpot: hotSpot)
    }

    // MARK: - Cached cursors

    // Brush / eraser / eyedropper: tip at bottom-left of the icon (SF convention).
    static let brush: NSCursor      = fromSymbol("paintbrush.pointed.fill", hotSpot: CGPoint(x: 2, y: 18))
    static let eraser: NSCursor     = fromSymbol("eraser.fill",             hotSpot: CGPoint(x: 2, y: 18))
    static let eyedropper: NSCursor = fromSymbol("eyedropper.halffull",     hotSpot: CGPoint(x: 2, y: 18))

    // Fill: custom paint-bucket asset. Hotspot at the bucket's bottom tip.
    static let fill: NSCursor = fromAsset("paintbucket", hotSpot: CGPoint(x: 11, y: 20), size: 22)

    // Precision crosshair for selection/shape — system cursor, already visible everywhere.
    static let selection: NSCursor = NSCursor.crosshair
    static let shape: NSCursor     = NSCursor.crosshair

    // Pan uses the built-in hands.
    static let panHover: NSCursor  = NSCursor.openHand
    static let panActive: NSCursor = NSCursor.closedHand

    // Transform (no handle hover).
    static let transformIdle: NSCursor = NSCursor.arrow

    /// Default cursor to show for a tool when hovering the canvas with no
    /// per-context override (e.g. no selection under cursor, no transform
    /// handle under cursor).
    static func current(for tool: ToolType) -> NSCursor {
        switch tool {
        case .brush:       return brush
        case .eraser:      return eraser
        case .fill:        return fill
        case .eyedropper:  return eyedropper
        case .selection:   return selection
        case .shape:       return shape
        case .transform:   return transformIdle
        case .pan:         return panHover
        }
    }
}
