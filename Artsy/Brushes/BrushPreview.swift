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
        readback = try renderer.textureManager.makeSharedTexture(width: Int(size.width), height: Int(size.height),
                                                                 label: "Brush Preview")
    }

    /// A pressure-swelling wave, then a short stroke across it to show how a second pass
    /// takes. `size` is the brush size to draw at.
    func render(brush: BrushDescriptor, color: StrokeColor, size brushSize: Float) -> CGImage? {
        guard let layer = viewModel.layerStack?.activeLayer,
              let clear = renderer.context.commandQueue.makeCommandBuffer() else { return nil }
        renderer.textureManager.clearTexture(layer.texture, commandBuffer: clear)
        clear.commit()

        viewModel.currentBrush = brush
        viewModel.brushSize = min(brushSize, Float(size.height) * 0.45)
        viewModel.brushOpacity = 1
        viewModel.currentColor = color
        viewModel.undoManager.clear()

        let w = size.width, h = size.height
        draw(samples(count: 160, duration: 0.8) { t in
            (CGPoint(x: w * (0.07 + 0.86 * t), y: h * (0.5 + 0.22 * sin(t * 2 * .pi))),
             Float(0.1 + 0.9 * sin(t * .pi)))
        })
        draw(samples(count: 50, duration: 0.25) { t in
            (CGPoint(x: w * (0.6 + 0.3 * t), y: h * (0.25 + 0.5 * t)), 0.6)
        })

        guard let commandBuffer = renderer.context.commandQueue.makeCommandBuffer() else { return nil }
        renderer.encodeFrame(into: commandBuffer)
        guard let blit = commandBuffer.makeBlitCommandEncoder() else { return nil }
        blit.copy(from: renderer.compositeTexture, to: readback)
        blit.endEncoding()
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()
        return Self.image(from: readback)
    }

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

    /// The composite, premultiplied over the white background layer, as an 8-bit image.
    private static func image(from texture: MTLTexture) -> CGImage? {
        let width = texture.width, height = texture.height
        var half = [UInt16](repeating: 0, count: width * height * 4)
        half.withUnsafeMutableBytes {
            texture.getBytes($0.baseAddress!, bytesPerRow: width * 8,
                             from: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0)
        }
        var rgba = [UInt8](repeating: 255, count: width * height * 4)
        for i in 0..<(width * height) {
            let a = Float(Float16(bitPattern: half[i * 4 + 3]))
            let through = 1 - a
            for c in 0..<3 {
                let value = Float(Float16(bitPattern: half[i * 4 + c])) + through
                rgba[i * 4 + c] = UInt8(max(0, min(255, (value * 255).rounded())))
            }
        }
        return rgba.withUnsafeMutableBytes { raw in
            CGContext(data: raw.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                      space: CGColorSpace(name: CGColorSpace.displayP3)!,
                      bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)?.makeImage()
        }
    }
}
