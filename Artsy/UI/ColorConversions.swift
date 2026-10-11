import AppKit
import SwiftUI

// Colour conversions between the engine's StrokeColor (Display P3) and the toolkits.

extension StrokeColor {
    var swiftUIColor: Color {
        Color(red: Double(red), green: Double(green), blue: Double(blue), opacity: Double(alpha))
    }

    var nsColor: NSColor {
        // Create as Display P3 since the pipeline stores and renders in P3
        NSColor(displayP3Red: CGFloat(red), green: CGFloat(green), blue: CGFloat(blue), alpha: CGFloat(alpha))
    }
}

extension Color {
    var strokeColor: StrokeColor {
        // Read the raw CGColor components — no color space conversion, so the
        // values the user typed in the color picker are what gets stored.
        let cg = NSColor(self).cgColor
        let components = cg.components ?? []
        let r = components.count > 0 ? Float(components[0]) : 0
        let g = components.count > 1 ? Float(components[1]) : 0
        let b = components.count > 2 ? Float(components[2]) : 0
        let a = cg.alpha
        return StrokeColor(red: r, green: g, blue: b, alpha: Float(a))
    }
}

extension NSColor {
    /// Convert an NSColor (from NSColorPanel) into a StrokeColor in Display P3.
    var strokeColor: StrokeColor {
        let p3 = self.usingColorSpace(.displayP3) ?? self
        return StrokeColor(
            red: Float(p3.redComponent),
            green: Float(p3.greenComponent),
            blue: Float(p3.blueComponent),
            alpha: Float(p3.alphaComponent)
        )
    }
}
