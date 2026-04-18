import Foundation

final class StrokeInterpolator {

    /// Interpolate between raw stroke points using Catmull-Rom splines.
    func interpolate(
        points: [StrokePoint],
        spacing: Float,
        brushSize: Float,
        pressureCurve: PressureCurve,
        dynamics: PressureDynamics
    ) -> [InterpolatedPoint] {
        guard points.count >= 2 else {
            if let p = points.first {
                let mapped = pressureCurve.map(p.pressure)
                return [InterpolatedPoint(
                    position: p.position,
                    pressure: mapped,
                    width: dynamics.size(for: mapped) * brushSize,
                    opacity: dynamics.opacity(for: mapped),
                    angle: 0
                )]
            }
            return []
        }

        var result: [InterpolatedPoint] = []
        // Sample at 1 pixel intervals for maximum smoothness
        let stepDist: CGFloat = 1.0

        for i in 0..<points.count - 1 {
            let p0 = points[max(0, i - 1)]
            let p1 = points[i]
            let p2 = points[min(points.count - 1, i + 1)]
            let p3 = points[min(points.count - 1, i + 2)]

            let segLen = hypot(p2.position.x - p1.position.x, p2.position.y - p1.position.y)
            guard segLen > 0.01 else { continue }

            // Subdivide this segment based on step distance
            let numSteps = max(1, Int(ceil(segLen / stepDist)))
            let dt = 1.0 / CGFloat(numSteps)

            let startStep = (i == 0) ? 0 : 1 // skip first point of subsequent segments (already added)
            for step in startStep...numSteps {
                let t = CGFloat(step) * dt

                let pos = catmullRom(t: t, p0: p0.position, p1: p1.position, p2: p2.position, p3: p3.position)

                // Interpolate pressure linearly between p1 and p2
                let rawPressure = lerp(Float(t), a: p1.pressure, b: p2.pressure)
                let mapped = pressureCurve.map(rawPressure)

                // Compute smooth tangent from the spline derivative
                let tangent = catmullRomTangent(t: t, p0: p0.position, p1: p1.position, p2: p2.position, p3: p3.position)
                let angle = Float(atan2(tangent.y, tangent.x))

                result.append(InterpolatedPoint(
                    position: pos,
                    pressure: mapped,
                    width: dynamics.size(for: mapped) * brushSize,
                    opacity: dynamics.opacity(for: mapped),
                    angle: angle
                ))
            }
        }

        return result
    }

    // MARK: - Catmull-Rom

    private func catmullRom(t: CGFloat, p0: CGPoint, p1: CGPoint, p2: CGPoint, p3: CGPoint) -> CGPoint {
        let t2 = t * t
        let t3 = t2 * t

        let x = 0.5 * ((2 * p1.x) +
            (-p0.x + p2.x) * t +
            (2 * p0.x - 5 * p1.x + 4 * p2.x - p3.x) * t2 +
            (-p0.x + 3 * p1.x - 3 * p2.x + p3.x) * t3)

        let y = 0.5 * ((2 * p1.y) +
            (-p0.y + p2.y) * t +
            (2 * p0.y - 5 * p1.y + 4 * p2.y - p3.y) * t2 +
            (-p0.y + 3 * p1.y - 3 * p2.y + p3.y) * t3)

        return CGPoint(x: x, y: y)
    }

    private func catmullRomTangent(t: CGFloat, p0: CGPoint, p1: CGPoint, p2: CGPoint, p3: CGPoint) -> CGPoint {
        let t2 = t * t

        let dx = 0.5 * ((-p0.x + p2.x) +
            2 * (2 * p0.x - 5 * p1.x + 4 * p2.x - p3.x) * t +
            3 * (-p0.x + 3 * p1.x - 3 * p2.x + p3.x) * t2)

        let dy = 0.5 * ((-p0.y + p2.y) +
            2 * (2 * p0.y - 5 * p1.y + 4 * p2.y - p3.y) * t +
            3 * (-p0.y + 3 * p1.y - 3 * p2.y + p3.y) * t2)

        return CGPoint(x: dx, y: dy)
    }

    private func lerp(_ t: Float, a: Float, b: Float) -> Float {
        a + t * (b - a)
    }
}
