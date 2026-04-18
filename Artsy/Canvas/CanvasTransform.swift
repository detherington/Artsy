import Foundation
import simd

struct CanvasTransform {
    var offset: CGPoint = .zero    // Pan offset in view coordinates
    var scale: CGFloat = 1.0       // Zoom level (0.1 to 32.0)
    var rotation: CGFloat = 0.0    // Canvas rotation in radians

    /// Convert view coordinates to canvas coordinates.
    func viewToCanvas(_ viewPoint: CGPoint, viewSize: CGSize) -> CGPoint {
        // View origin is bottom-left. Canvas origin is top-left conceptually,
        // but we keep both bottom-left for consistency.
        let cx = viewSize.width / 2 + offset.x
        let cy = viewSize.height / 2 + offset.y
        return CGPoint(
            x: (viewPoint.x - cx) / scale,
            y: (viewPoint.y - cy) / scale
        )
    }

    /// Convert canvas coordinates to view coordinates.
    func canvasToView(_ canvasPoint: CGPoint, viewSize: CGSize) -> CGPoint {
        let cx = viewSize.width / 2 + offset.x
        let cy = viewSize.height / 2 + offset.y
        return CGPoint(
            x: canvasPoint.x * scale + cx,
            y: canvasPoint.y * scale + cy
        )
    }

    /// Generate the transform matrix for the display shader.
    /// Maps canvas pixel coordinates → NDC (-1..1), centering the canvas in the view.
    func transformMatrix(viewSize: CGSize) -> float4x4 {
        // We want: NDC_x = (canvasX * scale + offsetX) * 2/viewWidth  - 1
        //          NDC_y = (canvasY * scale + offsetY) * 2/viewHeight - 1
        // But canvas is centered, so offset from center:
        //   NDC_x = ((canvasX * scale) + viewWidth/2 + offsetX) * 2/viewW - 1
        //         = canvasX * (2*scale/viewW) + (1 + 2*offsetX/viewW) - 1
        //         = canvasX * (2*scale/viewW) + 2*offsetX/viewW

        let sx = Float(2.0 * scale / viewSize.width)
        let sy = Float(2.0 * scale / viewSize.height)
        let tx = Float(2.0 * offset.x / viewSize.width)
        let ty = Float(2.0 * offset.y / viewSize.height)

        return float4x4(columns: (
            SIMD4<Float>( sx,  0,  0, 0),
            SIMD4<Float>(  0, sy,  0, 0),
            SIMD4<Float>(  0,  0,  1, 0),
            SIMD4<Float>( tx, ty,  0, 1)
        ))
    }

    mutating func zoom(by factor: CGFloat, at viewPoint: CGPoint, viewSize: CGSize) {
        let oldCanvasPoint = viewToCanvas(viewPoint, viewSize: viewSize)
        scale = max(0.1, min(32.0, scale * factor))
        let newViewPoint = canvasToView(oldCanvasPoint, viewSize: viewSize)
        offset.x += viewPoint.x - newViewPoint.x
        offset.y += viewPoint.y - newViewPoint.y
    }

    mutating func pan(by delta: CGPoint) {
        offset.x += delta.x
        offset.y += delta.y
    }

    mutating func zoomToFit(canvasSize: CGSize, viewSize: CGSize) {
        guard viewSize.width > 0, viewSize.height > 0 else { return }
        let scaleX = viewSize.width / canvasSize.width
        let scaleY = viewSize.height / canvasSize.height
        scale = min(scaleX, scaleY) * 0.9
        // Center canvas: offset so canvas center maps to view center
        // Canvas center in canvas coords = (canvasW/2, canvasH/2)
        // We want that to map to view center, which is offset=(0,0)
        // viewX = canvasX * scale + viewW/2 + offsetX
        // For canvasCenter → viewCenter: canvasW/2 * scale + viewW/2 + offsetX = viewW/2
        // So offsetX = -canvasW/2 * scale
        offset = CGPoint(
            x: -canvasSize.width / 2 * scale,
            y: -canvasSize.height / 2 * scale
        )
    }
}
