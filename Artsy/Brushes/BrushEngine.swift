import Foundation
import Metal

/// Vertex data for one piece of a stroke.
/// Vertex layout: position (float2), texCoord (float2), opacity (float) = 5 floats per vertex.
struct StrokeGeometry {
    var ribbonVertices: [Float] = []
    var ribbonIndices: [UInt32] = []
    var capVertices: [Float] = []
    var capIndices: [UInt32] = []
    /// Canvas-space box around every vertex; `.null` when there is no geometry.
    var bounds: CGRect = .null

    var isEmpty: Bool { ribbonIndices.isEmpty && capIndices.isEmpty }
}

/// The BrushEngine converts interpolated stroke points into vertex data
/// suitable for GPU rendering. Uses a triangle strip along the stroke path
/// to produce smooth, continuous strokes without stamp overlap artifacts.
final class BrushEngine {

    /// Geometry for `points[range]`: a ribbon with two vertices per point (left and right of
    /// the stroke center), plus optional round caps on the range's first and last point.
    ///
    /// A stroke is drawn in pieces as it grows. Cross-sections are computed from each point's
    /// neighbours in the whole array, not just the range, so two pieces that meet at a point
    /// share exactly the same edge there.
    ///
    /// - Parameter transform: applied to every position first (symmetry mirrors).
    func generateGeometry(
        for points: [InterpolatedPoint],
        range: ClosedRange<Int>,
        brush: BrushDescriptor,
        startCap: Bool,
        endCap: Bool,
        transform: ((CGPoint) -> CGPoint)? = nil
    ) -> StrokeGeometry {
        var geometry = StrokeGeometry()
        guard !points.isEmpty, range.lowerBound >= 0, range.upperBound < points.count else { return geometry }

        func position(_ index: Int) -> CGPoint {
            transform?(points[index].position) ?? points[index].position
        }

        var minX = Float.greatestFiniteMagnitude, minY = Float.greatestFiniteMagnitude
        var maxX = -Float.greatestFiniteMagnitude, maxY = -Float.greatestFiniteMagnitude
        func include(_ x: Float, _ y: Float) {
            minX = min(minX, x); maxX = max(maxX, x)
            minY = min(minY, y); maxY = max(maxY, y)
        }

        // 1. Ribbon (needs at least two points)
        if range.count >= 2 {
            geometry.ribbonVertices.reserveCapacity(range.count * 5 * 2)
            geometry.ribbonIndices.reserveCapacity((range.count - 1) * 6)

            // If the brush has a fixedNibAngle (calligraphy), every ribbon cross-section
            // uses the SAME perpendicular direction, which produces the classic
            // thick-when-perpendicular-to-nib / thin-when-along-nib variation — unless the
            // pen reports barrel rotation, which turns the nib with it.
            let nibAngle = brush.fixedNibAngle

            for (offset, i) in range.enumerated() {
                let point = points[i]
                let center = position(i)
                let cx = Float(center.x)
                let cy = Float(center.y)

                let perpX: Float
                let perpY: Float
                if let nibAngle {
                    perpX = cos(nibAngle + point.rotation)
                    perpY = sin(nibAngle + point.rotation)
                } else {
                    // Perpendicular to the direction between the neighbours on either side
                    let before = position(max(i - 1, 0))
                    let after = position(min(i + 1, points.count - 1))
                    let dx = Float(after.x - before.x)
                    let dy = Float(after.y - before.y)
                    let len = max(sqrt(dx * dx + dy * dy), 0.001)
                    perpX = -dy / len
                    perpY = dx / len
                }

                let halfWidth = point.width / 2.0
                let opacity = point.opacity * brush.opacity

                // Left vertex
                geometry.ribbonVertices += [cx + perpX * halfWidth, cy + perpY * halfWidth, 0.0, 0.0, opacity]
                // Right vertex
                geometry.ribbonVertices += [cx - perpX * halfWidth, cy - perpY * halfWidth, 1.0, 0.0, opacity]
                include(cx + perpX * halfWidth, cy + perpY * halfWidth)
                include(cx - perpX * halfWidth, cy - perpY * halfWidth)

                // Create two triangles connecting to previous pair of vertices
                if offset > 0 {
                    let base = UInt32((offset - 1) * 2)
                    // Triangle 1: prev-left, prev-right, curr-left
                    // Triangle 2: prev-right, curr-right, curr-left
                    geometry.ribbonIndices += [base, base + 1, base + 2, base + 1, base + 3, base + 2]
                }
            }
        }

        // 2. Round caps: tip quads drawn with a radial-distance shader.
        // Skipped for fixed-nib (calligraphy) brushes — round caps would spoil the crisp
        // angular nib look. The ribbon's edges are the correct shape.
        if brush.fixedNibAngle == nil {
            var capIndicesInPoints: [Int] = []
            if startCap { capIndicesInPoints.append(range.lowerBound) }
            if endCap, !(startCap && range.count == 1) { capIndicesInPoints.append(range.upperBound) }

            for (n, i) in capIndicesInPoints.enumerated() {
                let p = points[i]
                let center = position(i)
                let halfSize = p.width / 2.0
                let cx = Float(center.x)
                let cy = Float(center.y)
                let opacity = p.opacity * brush.opacity

                let base = UInt32(n * 4)
                // bottom-left, bottom-right, top-right, top-left with radial texCoords
                geometry.capVertices += [
                    cx - halfSize, cy - halfSize, 0, 1, opacity,
                    cx + halfSize, cy - halfSize, 1, 1, opacity,
                    cx + halfSize, cy + halfSize, 1, 0, opacity,
                    cx - halfSize, cy + halfSize, 0, 0, opacity,
                ]
                geometry.capIndices += [base, base + 1, base + 2, base, base + 2, base + 3]
                include(cx - halfSize, cy - halfSize)
                include(cx + halfSize, cy + halfSize)
            }
        }

        if !geometry.isEmpty {
            geometry.bounds = CGRect(x: CGFloat(minX), y: CGFloat(minY),
                                     width: CGFloat(maxX - minX), height: CGFloat(maxY - minY))
        }
        return geometry
    }
}
