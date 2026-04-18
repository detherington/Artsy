import Foundation
import CoreGraphics

struct CodablePoint: Codable, Equatable {
    let x: CGFloat
    let y: CGFloat

    var cgPoint: CGPoint { CGPoint(x: x, y: y) }

    init(x: CGFloat, y: CGFloat) {
        self.x = x
        self.y = y
    }

    init(_ point: CGPoint) {
        self.x = point.x
        self.y = point.y
    }
}

struct PressureCurve: Codable, Equatable {
    let controlPoint1: CodablePoint
    let controlPoint2: CodablePoint

    init(controlPoint1: CGPoint, controlPoint2: CGPoint) {
        self.controlPoint1 = CodablePoint(controlPoint1)
        self.controlPoint2 = CodablePoint(controlPoint2)
    }

    static let linear = PressureCurve(
        controlPoint1: CGPoint(x: 0.25, y: 0.25),
        controlPoint2: CGPoint(x: 0.75, y: 0.75)
    )
    static let soft = PressureCurve(
        controlPoint1: CGPoint(x: 0.1, y: 0.4),
        controlPoint2: CGPoint(x: 0.5, y: 0.9)
    )
    static let firm = PressureCurve(
        controlPoint1: CGPoint(x: 0.5, y: 0.1),
        controlPoint2: CGPoint(x: 0.9, y: 0.6)
    )

    func map(_ rawPressure: Float) -> Float {
        let t = Self.solveCubicBezierT(for: CGFloat(rawPressure), p1x: controlPoint1.x, p2x: controlPoint2.x)
        let y = Self.cubicBezierY(t: t, p1y: controlPoint1.y, p2y: controlPoint2.y)
        return Float(max(0, min(1, y)))
    }

    private static func solveCubicBezierT(for x: CGFloat, p1x: CGFloat, p2x: CGFloat, iterations: Int = 8) -> CGFloat {
        var t = x
        for _ in 0..<iterations {
            let currentX = cubicBezierX(t: t, p1x: p1x, p2x: p2x)
            let dx = cubicBezierDX(t: t, p1x: p1x, p2x: p2x)
            guard abs(dx) > 1e-6 else { break }
            t -= (currentX - x) / dx
            t = max(0, min(1, t))
        }
        return t
    }

    private static func cubicBezierX(t: CGFloat, p1x: CGFloat, p2x: CGFloat) -> CGFloat {
        let mt = 1 - t
        return 3 * mt * mt * t * p1x + 3 * mt * t * t * p2x + t * t * t
    }

    private static func cubicBezierY(t: CGFloat, p1y: CGFloat, p2y: CGFloat) -> CGFloat {
        let mt = 1 - t
        return 3 * mt * mt * t * p1y + 3 * mt * t * t * p2y + t * t * t
    }

    private static func cubicBezierDX(t: CGFloat, p1x: CGFloat, p2x: CGFloat) -> CGFloat {
        let mt = 1 - t
        return 3 * mt * mt * p1x + 6 * mt * t * (p2x - p1x) + 3 * t * t * (1 - p2x)
    }
}

struct PressureDynamics: Codable, Equatable {
    let sizeMin: Float
    let sizeMax: Float
    let opacityMin: Float
    let opacityMax: Float
    let flowMin: Float
    let flowMax: Float

    var sizeRange: ClosedRange<Float> { sizeMin...sizeMax }
    var opacityRange: ClosedRange<Float> { opacityMin...opacityMax }
    var flowRange: ClosedRange<Float> { flowMin...flowMax }

    init(sizeRange: ClosedRange<Float>, opacityRange: ClosedRange<Float>, flowRange: ClosedRange<Float>) {
        self.sizeMin = sizeRange.lowerBound
        self.sizeMax = sizeRange.upperBound
        self.opacityMin = opacityRange.lowerBound
        self.opacityMax = opacityRange.upperBound
        self.flowMin = flowRange.lowerBound
        self.flowMax = flowRange.upperBound
    }

    func size(for pressure: Float) -> Float {
        sizeMin + pressure * (sizeMax - sizeMin)
    }

    func opacity(for pressure: Float) -> Float {
        opacityMin + pressure * (opacityMax - opacityMin)
    }

    func flow(for pressure: Float) -> Float {
        flowMin + pressure * (flowMax - flowMin)
    }
}
