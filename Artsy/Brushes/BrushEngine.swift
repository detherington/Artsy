import Foundation
import Metal

/// The BrushEngine converts interpolated stroke points into vertex data
/// suitable for GPU rendering. Uses a triangle strip along the stroke path
/// to produce smooth, continuous strokes without stamp overlap artifacts.
final class BrushEngine {

    // Vertex layout: position (float2), texCoord (float2), opacity (float) = 5 floats per vertex

    /// Generate a triangle strip along the stroke path.
    /// Each interpolated point produces two vertices (left and right of the stroke center),
    /// forming a continuous ribbon that avoids the dark-dot overlap artifacts of stamp-based rendering.
    func generateStripVertices(
        for points: [InterpolatedPoint],
        brush: BrushDescriptor
    ) -> (vertices: [Float], indices: [UInt32]) {
        // Single point or empty — no ribbon geometry (caps handle single points)
        guard points.count >= 2 else { return ([], []) }

        var vertices: [Float] = []
        var indices: [UInt32] = []

        vertices.reserveCapacity(points.count * 5 * 2)
        indices.reserveCapacity((points.count - 1) * 6)

        // Pre-compute perpendicular normals for all points.
        // If the brush has a fixedNibAngle (calligraphy), every ribbon cross-section
        // uses the SAME perpendicular direction, which produces the classic
        // thick-when-perpendicular-to-nib / thin-when-along-nib variation.
        var normals = [(Float, Float)]()
        normals.reserveCapacity(points.count)

        if let nibAngle = brush.fixedNibAngle {
            let nx = cos(nibAngle)
            let ny = sin(nibAngle)
            for _ in 0..<points.count {
                normals.append((nx, ny))
            }
        } else {
            for i in 0..<points.count {
                let dx: Float
                let dy: Float
                if i == 0 {
                    dx = Float(points[1].position.x - points[0].position.x)
                    dy = Float(points[1].position.y - points[0].position.y)
                } else if i == points.count - 1 {
                    dx = Float(points[i].position.x - points[i-1].position.x)
                    dy = Float(points[i].position.y - points[i-1].position.y)
                } else {
                    dx = Float(points[i+1].position.x - points[i-1].position.x)
                    dy = Float(points[i+1].position.y - points[i-1].position.y)
                }
                let len = max(sqrt(dx * dx + dy * dy), 0.001)
                normals.append((-dy / len, dx / len))
            }
        }

        // Generate vertices
        for (i, point) in points.enumerated() {
            let halfWidth = point.width / 2.0
            let opacity = point.opacity * brush.opacity
            let cx = Float(point.position.x)
            let cy = Float(point.position.y)
            let (perpX, perpY) = normals[i]

            // Left vertex
            vertices.append(cx + perpX * halfWidth)
            vertices.append(cy + perpY * halfWidth)
            vertices.append(0.0)
            vertices.append(0.0)
            vertices.append(opacity)

            // Right vertex
            vertices.append(cx - perpX * halfWidth)
            vertices.append(cy - perpY * halfWidth)
            vertices.append(1.0)
            vertices.append(0.0)
            vertices.append(opacity)

            // Create two triangles connecting to previous pair of vertices
            if i > 0 {
                let base = UInt32((i - 1) * 2)
                // Triangle 1: prev-left, prev-right, curr-left
                indices.append(base + 0)
                indices.append(base + 1)
                indices.append(base + 2)
                // Triangle 2: prev-right, curr-right, curr-left
                indices.append(base + 1)
                indices.append(base + 3)
                indices.append(base + 2)
            }
        }

        // Caps are drawn separately via `generateCapVertices` using a radial shader
        return (vertices, indices)
    }

    /// Generate tip-quad vertices for the start and end points of a stroke, suitable
    /// for rendering with a radial-distance shader to produce rounded caps.
    func generateCapVertices(
        for points: [InterpolatedPoint],
        brush: BrushDescriptor
    ) -> (vertices: [Float], indices: [UInt32]) {
        guard !points.isEmpty else { return ([], []) }

        var vertices: [Float] = []
        var indices: [UInt32] = []

        let capPoints: [InterpolatedPoint]
        if points.count == 1 {
            capPoints = points
        } else {
            capPoints = [points.first!, points.last!]
        }

        for (i, p) in capPoints.enumerated() {
            let halfSize = p.width / 2.0
            let cx = Float(p.position.x)
            let cy = Float(p.position.y)
            let opacity = p.opacity * brush.opacity

            let base = UInt32(i * 4)
            // bottom-left, bottom-right, top-right, top-left with radial texCoords
            vertices += [
                cx - halfSize, cy - halfSize, 0, 1, opacity,
                cx + halfSize, cy - halfSize, 1, 1, opacity,
                cx + halfSize, cy + halfSize, 1, 0, opacity,
                cx - halfSize, cy + halfSize, 0, 0, opacity,
            ]
            indices += [base, base + 1, base + 2, base, base + 2, base + 3]
        }

        return (vertices, indices)
    }

}
