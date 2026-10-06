import Foundation

/// How a brush responds to the pen leaning over. Nothing happens while the pen is close to
/// upright; the effect comes in as it approaches flat, like shading with the side of a pencil.
struct TiltDynamics: Codable, Equatable {
    /// Size multiplier when the pen is flat.
    var sizeScale: Float
    /// Opacity multiplier when the pen is flat.
    var opacityScale: Float
    /// How much longer than wide a dab becomes when the pen is flat (1 = stays round).
    /// The long side follows the direction the pen leans in.
    var aspect: Float

    /// 0 while the pen is near upright, 1 when flat. `tilt` is NSEvent's -1...1 per axis.
    static func amount(of tilt: SIMD2<Float>) -> Float {
        let lean = min(1, (tilt.x * tilt.x + tilt.y * tilt.y).squareRoot())
        let t = min(1, max(0, (lean - 0.15) / 0.7))
        return t * t * (3 - 2 * t)
    }
}

/// How a brush responds to the speed of the stroke: a loaded brush thins as it is swept faster.
struct VelocityDynamics: Codable, Equatable {
    /// Canvas pixels per second at which the effect is fully on.
    var referenceSpeed: Float
    /// Size multiplier at the reference speed.
    var sizeScale: Float
    /// Opacity multiplier at the reference speed.
    var opacityScale: Float

    /// 0 at rest, 1 at the reference speed.
    func amount(atSpeed speed: Float) -> Float {
        min(1, max(0, speed / referenceSpeed))
    }
}
