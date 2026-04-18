import Foundation

struct StrokePoint {
    let position: CGPoint       // Canvas-space coordinates
    let pressure: Float         // 0.0 to 1.0 (raw from tablet)
    let tiltX: Float            // -1.0 to 1.0
    let tiltY: Float            // -1.0 to 1.0
    let rotation: Float         // Barrel rotation in degrees
    let timestamp: TimeInterval // For velocity calculation

    static func velocity(from p1: StrokePoint, to p2: StrokePoint) -> Float {
        let dx = Float(p2.position.x - p1.position.x)
        let dy = Float(p2.position.y - p1.position.y)
        let dt = Float(p2.timestamp - p1.timestamp)
        guard dt > 0 else { return 0 }
        return sqrt(dx * dx + dy * dy) / dt
    }
}

struct InterpolatedPoint {
    let position: CGPoint
    let pressure: Float          // Interpolated pressure
    let width: Float             // After pressure curve mapping
    let opacity: Float           // After pressure curve mapping
    let angle: Float             // Stroke direction in radians
}

struct StrokeColor: Codable, Equatable {
    let red: Float
    let green: Float
    let blue: Float
    let alpha: Float

    static let black = StrokeColor(red: 0, green: 0, blue: 0, alpha: 1)
    static let white = StrokeColor(red: 1, green: 1, blue: 1, alpha: 1)

    var simd: SIMD4<Float> {
        SIMD4(red, green, blue, alpha)
    }
}
