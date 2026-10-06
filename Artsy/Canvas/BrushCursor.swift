import AppKit

/// A ring the size of the brush tip, so the area a stroke will cover is visible before
/// the pen touches down. Drawn white inside black so it reads on canvases of any color.
enum BrushCursor {
    /// Below this the ring is too small to see; above it the image is larger than a cursor
    /// can usefully be. Either way a crosshair marks the centre instead.
    static let ringDiameters: ClosedRange<CGFloat> = 6...512

    private static var cache: [Int: NSCursor] = [:]

    /// - Parameter diameter: the brush's full-pressure width in screen points.
    static func cursor(diameter: CGFloat) -> NSCursor {
        guard ringDiameters.contains(diameter) else { return precise }
        let key = Int(diameter.rounded())
        if let cached = cache[key] { return cached }
        if cache.count > 128 { cache.removeAll() }

        let image = ringImage(diameter: CGFloat(key))
        let cursor = NSCursor(image: image, hotSpot: NSPoint(x: image.size.width / 2, y: image.size.height / 2))
        cache[key] = cursor
        return cursor
    }

    static func ringImage(diameter: CGFloat) -> NSImage {
        let pad: CGFloat = 2
        let side = diameter + pad * 2
        return NSImage(size: NSSize(width: side, height: side), flipped: false) { _ in
            let outer = NSBezierPath(ovalIn: NSRect(x: pad - 0.5, y: pad - 0.5, width: diameter + 1, height: diameter + 1))
            outer.lineWidth = 1
            NSColor.black.withAlphaComponent(0.85).setStroke()
            outer.stroke()

            let inner = NSBezierPath(ovalIn: NSRect(x: pad + 0.5, y: pad + 0.5, width: diameter - 1, height: diameter - 1))
            inner.lineWidth = 1
            NSColor.white.setStroke()
            inner.stroke()
            return true
        }
    }

    /// Four ticks around an open centre.
    private static let precise: NSCursor = {
        let side: CGFloat = 19
        let image = NSImage(size: NSSize(width: side, height: side), flipped: false) { _ in
            let c = side / 2
            for (color, width) in [(NSColor.black.withAlphaComponent(0.85), CGFloat(3)), (NSColor.white, CGFloat(1))] {
                let ticks = NSBezierPath()
                for (dx, dy) in [(CGFloat(1), CGFloat(0)), (-1, 0), (0, 1), (0, -1)] {
                    ticks.move(to: NSPoint(x: c + dx * 3, y: c + dy * 3))
                    ticks.line(to: NSPoint(x: c + dx * 8, y: c + dy * 8))
                }
                ticks.lineWidth = width
                color.setStroke()
                ticks.stroke()
            }
            return true
        }
        return NSCursor(image: image, hotSpot: NSPoint(x: side / 2, y: side / 2))
    }()
}
