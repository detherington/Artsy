import Foundation
import Metal
import AppKit
import CoreGraphics

final class ImageExporter {

    /// Export the composite canvas to PNG data suitable for AI API submission.
    static func exportForAI(
        renderer: CanvasRenderer,
        maxDimension: Int = 2048
    ) -> Data? {
        // First, composite all layers to a fresh shared texture we can read from
        guard let viewModel = renderer.viewModel,
              let layerStack = viewModel.layerStack else { return nil }

        let width = Int(renderer.canvasSize.width)
        let height = Int(renderer.canvasSize.height)

        guard let readableTexture = try? renderer.textureManager.makeSharedTexture(
            width: width, height: height, label: "Export"
        ) else { return nil }

        // Pass 1: Clear to white
        guard let cb1 = renderer.context.commandQueue.makeCommandBuffer() else { return nil }
        renderer.textureManager.clearTexture(readableTexture, commandBuffer: cb1,
            color: MTLClearColor(red: 1, green: 1, blue: 1, alpha: 1))
        cb1.commit()
        cb1.waitUntilCompleted()

        // Pass 2: Composite all layers
        guard let cb2 = renderer.context.commandQueue.makeCommandBuffer() else { return nil }
        for layer in layerStack.layers where layer.isVisible {
            renderer.compositor.compositeNormal(
                source: layer.texture,
                onto: readableTexture,
                opacity: layer.opacity,
                commandBuffer: cb2
            )
        }
        cb2.commit()
        cb2.waitUntilCompleted()

        // Read pixels from the shared texture
        return textureToData(texture: readableTexture, width: width, height: height, format: .png)
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
        guard let viewModel = renderer.viewModel,
              let layerStack = viewModel.layerStack else { throw ExportError.exportFailed }

        let width = Int(renderer.canvasSize.width)
        let height = Int(renderer.canvasSize.height)

        guard let readableTexture = try? renderer.textureManager.makeSharedTexture(
            width: width, height: height, label: "Export JPEG"
        ) else { throw ExportError.exportFailed }

        guard let cb1 = renderer.context.commandQueue.makeCommandBuffer() else { throw ExportError.exportFailed }
        renderer.textureManager.clearTexture(readableTexture, commandBuffer: cb1,
            color: MTLClearColor(red: 1, green: 1, blue: 1, alpha: 1))
        cb1.commit()
        cb1.waitUntilCompleted()

        guard let cb2 = renderer.context.commandQueue.makeCommandBuffer() else { throw ExportError.exportFailed }
        for layer in layerStack.layers where layer.isVisible {
            renderer.compositor.compositeNormal(
                source: layer.texture,
                onto: readableTexture,
                opacity: layer.opacity,
                commandBuffer: cb2
            )
        }
        cb2.commit()
        cb2.waitUntilCompleted()

        guard let data = textureToData(texture: readableTexture, width: width, height: height, format: .jpeg(quality: quality)) else {
            throw ExportError.exportFailed
        }
        try data.write(to: url)
    }

    // MARK: - Texture to Data

    private enum ImageFormat {
        case png
        case jpeg(quality: CGFloat)
    }

    private static func textureToData(texture: MTLTexture, width: Int, height: Int, format: ImageFormat) -> Data? {
        // Read float16 RGBA pixels
        let bytesPerPixel = 8  // rgba16Float
        let bytesPerRow = width * bytesPerPixel
        var pixelData = [UInt8](repeating: 0, count: height * bytesPerRow)

        texture.getBytes(
            &pixelData,
            bytesPerRow: bytesPerRow,
            from: MTLRegion(origin: .init(x: 0, y: 0, z: 0),
                            size: .init(width: width, height: height, depth: 1)),
            mipmapLevel: 0
        )

        // Convert Float16 to UInt8
        let pixelCount = width * height
        var rgba = [UInt8](repeating: 255, count: pixelCount * 4)
        pixelData.withUnsafeBytes { raw in
            let f16 = raw.bindMemory(to: UInt16.self)
            for i in 0..<pixelCount {
                rgba[i*4+0] = clampByte(float16ToFloat(f16[i*4+0]))
                rgba[i*4+1] = clampByte(float16ToFloat(f16[i*4+1]))
                rgba[i*4+2] = clampByte(float16ToFloat(f16[i*4+2]))
                rgba[i*4+3] = clampByte(float16ToFloat(f16[i*4+3]))
            }
        }

        guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = CGContext(data: &rgba, width: width, height: height,
                                 bitsPerComponent: 8, bytesPerRow: width * 4,
                                 space: colorSpace,
                                 bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
              let cgImage = ctx.makeImage() else { return nil }

        let rep = NSBitmapImageRep(cgImage: cgImage)
        switch format {
        case .png:
            return rep.representation(using: .png, properties: [:])
        case .jpeg(let quality):
            return rep.representation(using: .jpeg, properties: [.compressionFactor: quality])
        }
    }

    private static func float16ToFloat(_ h: UInt16) -> Float {
        let sign = (h >> 15) & 0x1
        let exp = (h >> 10) & 0x1F
        let mant = h & 0x3FF
        if exp == 0 {
            if mant == 0 { return sign == 1 ? -0.0 : 0.0 }
            return (sign == 1 ? -1.0 : 1.0) * Float(mant) / 1024.0 * pow(2.0, -14.0)
        }
        if exp == 31 { return mant == 0 ? (sign == 1 ? -.infinity : .infinity) : .nan }
        return (sign == 1 ? -1.0 : 1.0) * (1.0 + Float(mant) / 1024.0) * pow(2.0, Float(exp) - 15.0)
    }

    private static func clampByte(_ f: Float) -> UInt8 {
        UInt8(max(0, min(255, f * 255)))
    }
}

enum ExportError: LocalizedError {
    case exportFailed

    var errorDescription: String? {
        "Failed to export canvas"
    }
}
