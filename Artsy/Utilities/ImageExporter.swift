import Foundation
import Metal
import AppKit
import CoreGraphics

final class ImageExporter {

    /// The canvas as it looks on screen: every visible layer composited, over white, thick
    /// paint lit. CPU-readable, the size of the canvas: 8-bit BGRA, or half floats for
    /// `bitsPerChannel` 16.
    static func litCanvas(renderer: CanvasRenderer, bitsPerChannel: Int = 8) -> MTLTexture? {
        let width = Int(renderer.canvasSize.width), height = Int(renderer.canvasSize.height)
        let desc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: bitsPerChannel == 16 ? .rgba16Float : .bgra8Unorm, width: width, height: height, mipmapped: false
        )
        desc.usage = [.renderTarget, .shaderRead]
        #if arch(arm64)
        desc.storageMode = .shared
        #else
        desc.storageMode = .managed
        #endif
        guard let target = renderer.context.device.makeTexture(descriptor: desc),
              let commandBuffer = renderer.context.commandQueue.makeCommandBuffer() else { return nil }

        renderer.encodeFrame(into: commandBuffer)
        // Canvas pixels one to one with the target's
        var transform = CanvasTransform()
        transform.scale = 1
        transform.offset = CGPoint(x: -Double(width) / 2, y: -Double(height) / 2)
        renderer.compositor.renderToScreen(
            composite: renderer.compositeTexture, height: renderer.compositeHeightTexture,
            relief: Float(AppPreferences.shared.paintRelief), drawable: target, transform: transform,
            viewSize: CGSize(width: width, height: height), backgroundColor: (1, 1, 1), commandBuffer: commandBuffer
        )
        #if !arch(arm64)
        if let blit = commandBuffer.makeBlitCommandEncoder() {
            blit.synchronize(resource: target)
            blit.endEncoding()
        }
        #endif
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()
        return target
    }

    /// Export the canvas to PNG data suitable for AI API submission.
    static func exportForAI(
        renderer: CanvasRenderer,
        maxDimension: Int = 2048
    ) -> Data? {
        guard let canvas = litCanvas(renderer: renderer) else { return nil }
        return imageData(from: canvas, format: .png)
    }

    /// Export the canvas to a PNG file, with 8 or 16 bits per channel.
    static func exportPNG(renderer: CanvasRenderer, to url: URL, bitsPerChannel: Int = 8) throws {
        guard let canvas = litCanvas(renderer: renderer, bitsPerChannel: bitsPerChannel),
              let data = imageData(from: canvas, format: .png) else {
            throw ExportError.exportFailed
        }
        try data.write(to: url)
    }

    /// Export the canvas to JPEG file.
    static func exportJPEG(renderer: CanvasRenderer, to url: URL, quality: CGFloat = 0.9) throws {
        guard let canvas = litCanvas(renderer: renderer),
              let data = imageData(from: canvas, format: .jpeg(quality: quality)) else {
            throw ExportError.exportFailed
        }
        try data.write(to: url)
    }

    // MARK: - Texture to Data

    private enum ImageFormat {
        case png
        case jpeg(quality: CGFloat)
    }

    /// Encode a CPU-readable texture from `litCanvas`: 8-bit BGRA, or half floats as 16-bit
    /// PNG. Tagged Display P3, the colour space the canvas is drawn in.
    private static func imageData(from texture: MTLTexture, format: ImageFormat) -> Data? {
        let width = texture.width, height = texture.height
        guard let colorSpace = CGColorSpace(name: CGColorSpace.displayP3) else { return nil }
        let cgImage: CGImage?
        if texture.pixelFormat == .rgba16Float {
            var half = [UInt16](repeating: 0, count: width * height * 4)
            half.withUnsafeMutableBytes {
                texture.getBytes($0.baseAddress!, bytesPerRow: width * 8,
                                 from: MTLRegion(origin: .init(x: 0, y: 0, z: 0), size: .init(width: width, height: height, depth: 1)),
                                 mipmapLevel: 0)
            }
            let wide: [UInt16] = half.map { UInt16((max(0, min(1, Float(Float16(bitPattern: $0)))) * 65535).rounded()) }
            let data = wide.withUnsafeBufferPointer { Data(buffer: $0) }
            guard let provider = CGDataProvider(data: data as CFData) else { return nil }
            cgImage = CGImage(
                width: width, height: height, bitsPerComponent: 16, bitsPerPixel: 64, bytesPerRow: width * 8,
                space: colorSpace,
                bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue | CGBitmapInfo.byteOrder16Little.rawValue),
                provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent
            )
        } else {
            var bgra = [UInt8](repeating: 0, count: width * height * 4)
            texture.getBytes(
                &bgra,
                bytesPerRow: width * 4,
                from: MTLRegion(origin: .init(x: 0, y: 0, z: 0), size: .init(width: width, height: height, depth: 1)),
                mipmapLevel: 0
            )
            guard let ctx = CGContext(data: &bgra, width: width, height: height,
                                      bitsPerComponent: 8, bytesPerRow: width * 4,
                                      space: colorSpace,
                                      bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
            else { return nil }
            cgImage = ctx.makeImage()
        }
        guard let cgImage else { return nil }

        let rep = NSBitmapImageRep(cgImage: cgImage)
        switch format {
        case .png:
            return rep.representation(using: .png, properties: [:])
        case .jpeg(let quality):
            return rep.representation(using: .jpeg, properties: [.compressionFactor: quality])
        }
    }
}

enum ExportError: LocalizedError {
    case exportFailed

    var errorDescription: String? {
        "Failed to export canvas"
    }
}
