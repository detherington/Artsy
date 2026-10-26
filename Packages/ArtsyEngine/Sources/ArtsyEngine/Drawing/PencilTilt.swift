import Foundation

/// A pencil's lean as the engine takes it: the two components in -1...1 that a tablet
/// reports on the Mac, 0 upright and 1 flat, from the altitude and azimuth a Pencil
/// reports on iPad. The altitude is the angle to the surface, π/2 upright and 0 flat;
/// the azimuth is the direction the pencil leans, measured from the positive x axis.
public enum PencilTilt {
    /// - Parameter yDown: true when the azimuth was measured in a coordinate space whose
    ///   y axis points down (UIKit's), so the lean's y component comes out in the engine's
    ///   y-up view space, as the Mac's tablet reports it.
    public static func tilt(altitude: Double, azimuth: Double, yDown: Bool = true) -> (x: Float, y: Float) {
        let lean = 1 - min(max(altitude, 0), .pi / 2) / (.pi / 2)
        let x = Float(cos(azimuth) * lean)
        let y = Float(sin(azimuth) * lean) * (yDown ? -1 : 1)
        return (x, y)
    }
}
