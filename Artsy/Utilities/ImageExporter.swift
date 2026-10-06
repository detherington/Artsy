import Foundation
import Metal
import AppKit
import CoreGraphics

final class ImageExporter {

    /// The canvas as it looks on screen: every visible layer composited, over white, thick
    /// paint lit. 8-bit BGRA, CPU-readable, the size of the canvas.
    static func litCanvas(renderer: CanvasRenderer) -> MTLTexture? {
        let width = Int(renderer.canvasSize.width), height = Int(renderer.canvasSize.height)
        let desc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm, width: width, height: height, mipmapped: false
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

    /// Export the canvas to PNG file.
    static func exportPNG(renderer: CanvasRenderer, to url: URL) throws {
        guard let data = exportForAI(renderer: renderer, maxDimension: 0) else {
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

    /// Encode a CPU-readable 8-bit BGRA texture.
    private static func imageData(from texture: MTLTexture, format: ImageFormat) -> Data? {
        let width = texture.width, height = texture.height
        var bgra = [UInt8](repeating: 0, count: width * height * 4)
        texture.getBytes(
            &bgra,
            bytesPerRow: width * 4,
            from: MTLRegion(origin: .init(x: 0, y: 0, z: 0), size: .init(width: width, height: height, depth: 1)),
            mipmapLevel: 0
        )
        guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = CGContext(data: &bgra, width: width, height: height,
                                  bitsPerComponent: 8, bytesPerRow: width * 4,
                                  space: colorSpace,
                                  bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue),
              let cgImage = ctx.makeImage() else { return nil }

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
