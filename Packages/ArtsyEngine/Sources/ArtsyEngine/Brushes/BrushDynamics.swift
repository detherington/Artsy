import Foundation

/// How a brush responds to the pen leaning over. Nothing happens while the pen is close to
/// upright; the effect comes in as it approaches flat, like shading with the side of a pencil.
public struct TiltDynamics: Codable, Equatable {
    /// Size multiplier when the pen is flat.
    public var sizeScale: Float
    /// Opacity multiplier when the pen is flat.
    public var opacityScale: Float
    /// How much longer than wide a dab becomes when the pen is flat (1 = stays round).
    /// The long side follows the direction the pen leans in.
    public var aspect: Float

    /// 0 while the pen is near upright, 1 when flat. `tilt` is NSEvent's -1...1 per axis.
    public static func amount(of tilt: SIMD2<Float>) -> Float {
        let lean = min(1, (tilt.x * tilt.x + tilt.y * tilt.y).squareRoot())
        let t = min(1, max(0, (lean - 0.15) / 0.7))
        return t * t * (3 - 2 * t)
    }

    public init(sizeScale: Float, opacityScale: Float, aspect: Float) {
        self.sizeScale = sizeScale
        self.opacityScale = opacityScale
        self.aspect = aspect
    }

    /// The same lean without the fading, for a pen that has tilt but no pressure: leaning
    /// still broadens and lengthens the mark, but a lighter mark stood for the lighter
    /// touch of a pen laid on its side, which such a pen cannot tell from pressing.
    public var withoutFading: TiltDynamics { TiltDynamics(sizeScale: sizeScale, opacityScale: 1, aspect: aspect) }
}

/// How a brush responds to the speed of the stroke: a loaded brush thins as it is swept faster.
public struct VelocityDynamics: Codable, Equatable {
    /// Canvas pixels per second at which the effect is fully on.
    public var referenceSpeed: Float
    /// Size multiplier at the reference speed.
    public var sizeScale: Float
    /// Opacity multiplier at the reference speed.
    public var opacityScale: Float

    /// 0 at rest, 1 at the reference speed.
    public func amount(atSpeed speed: Float) -> Float {
        min(1, max(0, speed / referenceSpeed))
    }

    public init(referenceSpeed: Float, sizeScale: Float, opacityScale: Float) {
        self.referenceSpeed = referenceSpeed
        self.sizeScale = sizeScale
        self.opacityScale = opacityScale
    }
}
