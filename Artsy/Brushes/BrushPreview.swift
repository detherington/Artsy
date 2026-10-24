import Foundation
import Metal
import CoreGraphics

/// Renders a sample stroke with a brush, for the Brush Studio's preview pad. Draws through
/// the real engine on its own small canvas.
final class BrushPreview {
    let size: CGSize
    private let renderer: CanvasRenderer
    private let viewModel: CanvasViewModel
    private let readback: MTLTexture

    init(context: MetalContext, size: CGSize = CGSize(width: 360, height: 150)) throws {
        self.size = size
        viewModel = CanvasViewModel(canvasSize: size)
        viewModel.recorder = nil
        viewModel.smoothingMode = .none
        viewModel.symmetryMode = .off
        viewModel.easesStrokesWithoutPressure = false
        renderer = try CanvasRenderer(context: context, canvasSize: size)
        renderer.viewModel = viewModel
        try renderer.setupLayerStack(for: viewModel)
        // A wash on the pad dries at once, to show how it ends up
        renderer.dryingTimeOverride = 10
        readback = try renderer.textureManager.makeSharedTexture(width: Int(size.width), height: Int(size.height),
                                                                 label: "Brush Preview")
    }

    /// A pressure-swelling wave, then a short stroke across it to show how a second pass
    /// takes. `size` is the brush size to draw at.
    /// - Parameter onPaper: over the white paper, as an opaque image (the Studio's pad);
    ///   false for the stroke alone with its transparency, for a dark panel.
    func render(brush: BrushDescriptor, color: StrokeColor, size brushSize: Float, onPaper: Bool = true) -> CGImage? {
        guard let layerStack = viewModel.layerStack, let layer = layerStack.activeLayer,
              let clear = renderer.context.commandQueue.makeCommandBuffer() else { return nil }
        renderer.textureManager.clearTexture(layer.texture, commandBuffer: clear)
        clear.commit()
        layerStack.layers.first?.isVisible = onPaper

        let w = size.width, h = size.height
        viewModel.brushOpacity = 1

        // A smudge brush shows nothing on a blank pad: give it bands of paint to drag. Nor
        // does clean water: give it wet bands to push about.
        let clearsWater = brush.water != nil && brush.opacity <= 0.01
        if brush.smudgeSettings != nil || clearsWater {
            viewModel.currentBrush = clearsWater ? .watercolor : .hardRound
            viewModel.brushSize = Float(h) * 0.5
            for (index, band) in Self.paintBands.enumerated() {
                viewModel.currentColor = band
                let x = w * (0.22 + 0.28 * CGFloat(index))
                draw(samples(count: 20, duration: 0.1) { t in (CGPoint(x: x, y: h * (0.15 + 0.7 * t)), 1) })
            }
        }

        viewModel.currentBrush = brush
        viewModel.brushSize = min(brushSize, Float(size.height) * 0.45)
        viewModel.currentColor = color
        viewModel.undoManager.clear()

        draw(samples(count: 160, duration: 0.8) { t in
            (CGPoint(x: w * (0.07 + 0.86 * t), y: h * (0.5 + 0.22 * sin(t * 2 * .pi))),
             Float(0.1 + 0.9 * sin(t * .pi)))
        })
        draw(samples(count: 50, duration: 0.25) { t in
            (CGPoint(x: w * (0.6 + 0.3 * t), y: h * (0.25 + 0.5 * t)), 0.6)
        })
        // Water on the pad runs its course, so the tile shows the wash dried
        if layerStack.layers.contains(where: { $0.water != nil }) {
            renderer.runWater(for: Double(WaterRenderer.cap) * 10 + 2)
        }

        guard let commandBuffer = renderer.context.commandQueue.makeCommandBuffer() else { return nil }
        renderer.encodeFrame(into: commandBuffer)
        guard let blit = commandBuffer.makeBlitCommandEncoder() else { return nil }
        blit.copy(from: renderer.compositeTexture, sourceSlice: 0, sourceLevel: 0, sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0),
                  sourceSize: MTLSize(width: readback.width, height: readback.height, depth: 1),
                  to: readback, destinationSlice: 0, destinationLevel: 0, destinationOrigin: MTLOrigin(x: 0, y: 0, z: 0))
        blit.endEncoding()
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()
        return Self.image(from: readback, opaque: onPaper)
    }

    static let paintBands = [
        StrokeColor(red: 0.85, green: 0.20, blue: 0.18, alpha: 1),
        StrokeColor(red: 0.95, green: 0.75, blue: 0.15, alpha: 1),
        StrokeColor(red: 0.15, green: 0.40, blue: 0.80, alpha: 1),
    ]

    private func samples(count: Int, duration: Double, _ path: (Double) -> (CGPoint, Float)) -> [StrokePoint] {
        (0...count).map { i in
            let t = Double(i) / Double(count)
            let (position, pressure) = path(t)
            return StrokePoint(position: position, pressure: pressure, tiltX: 0, tiltY: 0, rotation: 0, timestamp: t * duration)
        }
    }

    private func draw(_ points: [StrokePoint]) {
        guard let first = points.first else { return }
        renderer.beginStroke()
        viewModel.beginStroke(point: first)
        points.dropFirst().forEach(viewModel.continueStroke(point:))
        renderer.finalizeStroke()
        viewModel.endStroke()
    }

    /// The composite as an 8-bit image: over white, opaque, or premultiplied with its alpha.
    private static func image(from texture: MTLTexture, opaque: Bool) -> CGImage? {
        let width = texture.width, height = texture.height
        var half = [UInt16](repeating: 0, count: width * height * 4)
        half.withUnsafeMutableBytes {
            texture.getBytes($0.baseAddress!, bytesPerRow: width * 8,
                             from: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0)
        }
        var rgba = [UInt8](repeating: 255, count: width * height * 4)
        for i in 0..<(width * height) {
            let a = Float(Float16(bitPattern: half[i * 4 + 3]))
            let through = opaque ? 1 - a : 0
            for c in 0..<3 {
                let value = Float(Float16(bitPattern: half[i * 4 + c])) + through
                rgba[i * 4 + c] = UInt8(max(0, min(255, (value * 255).rounded())))
            }
            if !opaque { rgba[i * 4 + 3] = UInt8(max(0, min(255, (a * 255).rounded()))) }
        }
        return rgba.withUnsafeMutableBytes { raw in
            CGContext(data: raw.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                      space: CGColorSpace(name: CGColorSpace.displayP3)!,
                      bitmapInfo: (opaque ? CGImageAlphaInfo.noneSkipLast : .premultipliedLast).rawValue)?.makeImage()
        }
    }
}
