import Foundation
import simd
import CoreGraphics

/// Where the canvas sits in the view: zoom, pan, rotation and a mirror, none of which
/// touch the pixels. A canvas point maps to the view as
///
///     view = viewCentre + offset + R(rotation) · F(flip) · (canvas × scale)
///
/// so `offset` is where the canvas origin lands, measured from the view's centre.
struct CanvasTransform: Equatable {
    var offset: CGPoint = .zero    // Pan offset in view coordinates
    var scale: CGFloat = 1.0       // Zoom level (0.1 to 32.0)
    var rotation: CGFloat = 0.0    // Canvas rotation in radians, counter-clockwise
    /// Mirror the view left-to-right. A fresh look at a drawing shows what the eye has got
    /// used to; the pixels are not changed.
    var isFlipped = false

    /// The canvas-to-view mapping without its translation: rotation, mirror and zoom.
    private var linear: (a: CGFloat, b: CGFloat, c: CGFloat, d: CGFloat) {
        let cosR = cos(rotation), sinR = sin(rotation)
        let sx = isFlipped ? -scale : scale
        // columns: x axis (a, b), y axis (c, d)
        return (a: cosR * sx, b: sinR * sx, c: -sinR * scale, d: cosR * scale)
    }

    /// Convert view coordinates to canvas coordinates.
    func viewToCanvas(_ viewPoint: CGPoint, viewSize: CGSize) -> CGPoint {
        let m = linear
        let x = viewPoint.x - (viewSize.width / 2 + offset.x)
        let y = viewPoint.y - (viewSize.height / 2 + offset.y)
        let det = m.a * m.d - m.b * m.c
        guard abs(det) > 1e-12 else { return .zero }
        return CGPoint(x: (m.d * x - m.c * y) / det, y: (-m.b * x + m.a * y) / det)
    }

    /// Convert canvas coordinates to view coordinates.
    func canvasToView(_ canvasPoint: CGPoint, viewSize: CGSize) -> CGPoint {
        let m = linear
        return CGPoint(
            x: m.a * canvasPoint.x + m.c * canvasPoint.y + viewSize.width / 2 + offset.x,
            y: m.b * canvasPoint.x + m.d * canvasPoint.y + viewSize.height / 2 + offset.y
        )
    }

    /// The same mapping for Core Graphics drawing (overlays, handles).
    func affineTransform(viewSize: CGSize) -> CGAffineTransform {
        let m = linear
        return CGAffineTransform(a: m.a, b: m.b, c: m.c, d: m.d,
                                 tx: viewSize.width / 2 + offset.x, ty: viewSize.height / 2 + offset.y)
    }

    /// Generate the transform matrix for the display shader.
    /// Maps canvas pixel coordinates → NDC (-1..1); the view's centre is NDC (0, 0).
    func transformMatrix(viewSize: CGSize) -> float4x4 {
        let m = linear
        let w = Float(2.0 / viewSize.width)
        let h = Float(2.0 / viewSize.height)
        return float4x4(columns: (
            SIMD4<Float>(Float(m.a) * w, Float(m.b) * h, 0, 0),
            SIMD4<Float>(Float(m.c) * w, Float(m.d) * h, 0, 0),
            SIMD4<Float>(0, 0, 1, 0),
            SIMD4<Float>(Float(offset.x) * w, Float(offset.y) * h, 0, 1)
        ))
    }

    mutating func zoom(by factor: CGFloat, at viewPoint: CGPoint, viewSize: CGSize) {
        let oldCanvasPoint = viewToCanvas(viewPoint, viewSize: viewSize)
        scale = max(0.1, min(32.0, scale * factor))
        keep(oldCanvasPoint, at: viewPoint, viewSize: viewSize)
    }

    /// Turn the canvas by `delta` radians about `viewPoint`, which stays put.
    mutating func rotate(by delta: CGFloat, at viewPoint: CGPoint, viewSize: CGSize) {
        let pinned = viewToCanvas(viewPoint, viewSize: viewSize)
        rotation = Self.normalized(rotation + delta)
        keep(pinned, at: viewPoint, viewSize: viewSize)
    }

    /// Set the rotation outright, keeping `viewPoint` put. Within two degrees of upright
    /// snaps to upright, so a nudge back to zero lands exactly.
    mutating func setRotation(_ angle: CGFloat, at viewPoint: CGPoint, viewSize: CGSize) {
        let pinned = viewToCanvas(viewPoint, viewSize: viewSize)
        let normalized = Self.normalized(angle)
        rotation = abs(normalized) < 2 * .pi / 180 ? 0 : normalized
        keep(pinned, at: viewPoint, viewSize: viewSize)
    }

    /// Mirror the view left-to-right about `viewPoint`.
    mutating func flip(at viewPoint: CGPoint, viewSize: CGSize) {
        let pinned = viewToCanvas(viewPoint, viewSize: viewSize)
        isFlipped.toggle()
        // Mirroring also reverses the sense of rotation on screen; keep the canvas's
        // apparent tilt by negating it.
        rotation = -rotation
        keep(pinned, at: viewPoint, viewSize: viewSize)
    }

    mutating func pan(by delta: CGPoint) {
        offset.x += delta.x
        offset.y += delta.y
    }

    mutating func zoomToFit(canvasSize: CGSize, viewSize: CGSize) {
        guard viewSize.width > 0, viewSize.height > 0 else { return }
        rotation = 0
        isFlipped = false
        let scaleX = viewSize.width / canvasSize.width
        let scaleY = viewSize.height / canvasSize.height
        scale = min(scaleX, scaleY) * 0.9
        // Centre the canvas: its middle maps to the view's centre, which is offset (0, 0)
        offset = CGPoint(
            x: -canvasSize.width / 2 * scale,
            y: -canvasSize.height / 2 * scale
        )
    }

    /// Move the view so `canvasPoint` lands on `viewPoint`.
    private mutating func keep(_ canvasPoint: CGPoint, at viewPoint: CGPoint, viewSize: CGSize) {
        let now = canvasToView(canvasPoint, viewSize: viewSize)
        offset.x += viewPoint.x - now.x
        offset.y += viewPoint.y - now.y
    }

    /// Wrap an angle into -π...π.
    private static func normalized(_ angle: CGFloat) -> CGFloat {
        var a = angle.truncatingRemainder(dividingBy: 2 * .pi)
        if a > .pi { a -= 2 * .pi }
        if a < -.pi { a += 2 * .pi }
        return a
    }
}
