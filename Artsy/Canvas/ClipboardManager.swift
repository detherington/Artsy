import Foundation
import Metal
import AppKit
import CoreGraphics

/// Cut / Copy / Paste for canvas pixels.
///
/// Copy runs asynchronously: main thread kicks off a GPU blit, and the
/// CPU-side F16→U8 conversion + PNG/TIFF encoding + pasteboard write
/// all happen on a background queue once the GPU completes. The main
/// thread never blocks. The pasteboard holds its previous contents until
/// the new copy finishes (so ⌘V right after ⌘C pastes the prior snapshot
/// if the encode is still in flight — rare in practice for typical use).
enum ClipboardManager {

    // MARK: - Copy

    /// Copy pixels from `layer`, cropped to the selection (if any), onto the
    /// system pasteboard. Returns immediately; the pasteboard is updated once
    /// the background encode completes.
    static func copyAsync(
        layer: Layer,
        canvasSize: CGSize,
        selectionPath: CGPath?,
        renderer: CanvasRenderer
    ) {
        let fullW = layer.texture.width
        let fullH = layer.texture.height

        guard let staging = try? renderer.textureManager.makeSharedTexture(
            width: fullW, height: fullH, label: "ClipboardRead"
        ),
        let cmdBuf = renderer.context.commandQueue.makeCommandBuffer(),
        let blit = cmdBuf.makeBlitCommandEncoder() else { return }
        blit.copy(from: layer.texture, to: staging)
        blit.endEncoding()

        let capturedSize = canvasSize
        let capturedPath = selectionPath

        cmdBuf.addCompletedHandler { _ in
            DispatchQueue.global(qos: .userInitiated).async {
                guard let fullImage = cgImageFromF16Texture(staging) else { return }
                let finalImage: CGImage
                if let path = capturedPath,
                   let cropped = maskedCrop(source: fullImage, path: path, canvasSize: capturedSize) {
                    finalImage = cropped
                } else {
                    finalImage = fullImage
                }
                writeImageToPasteboard(finalImage)
            }
        }
        cmdBuf.commit()
    }

    // MARK: - Paste

    /// Read the first image on the pasteboard as an NSImage, if any.
    static func readImage() -> NSImage? {
        let pb = NSPasteboard.general
        if let imgs = pb.readObjects(forClasses: [NSImage.self], options: nil) as? [NSImage],
           let img = imgs.first {
            return img
        }
        return nil
    }

    // MARK: - Private helpers

    private static func writeImageToPasteboard(_ cgImage: CGImage) {
        // Encode PNG via ImageIO (fast, SIMD-backed internally). Skip NSBitmapImageRep.
        let pngData = NSMutableData()
        if let dest = CGImageDestinationCreateWithData(
            pngData, "public.png" as CFString, 1, nil
        ) {
            CGImageDestinationAddImage(dest, cgImage, nil)
            CGImageDestinationFinalize(dest)
        }

        // TIFF is macOS's canonical pasteboard image type — include for widest
        // app compatibility. ImageIO again, but kUTTypeTIFF.
        let tiffData = NSMutableData()
        if let dest = CGImageDestinationCreateWithData(
            tiffData, "public.tiff" as CFString, 1, nil
        ) {
            CGImageDestinationAddImage(dest, cgImage, nil)
            CGImageDestinationFinalize(dest)
        }

        DispatchQueue.main.async {
            let pb = NSPasteboard.general
            pb.clearContents()
            if pngData.length > 0 {
                pb.setData(pngData as Data, forType: .png)
            }
            if tiffData.length > 0 {
                pb.setData(tiffData as Data, forType: .tiff)
            }
        }
    }

    /// Build an 8-bit RGBA CGImage from a rgba16Float MTLTexture via CoreGraphics.
    private static func cgImageFromF16Texture(_ texture: MTLTexture) -> CGImage? {
        let w = texture.width, h = texture.height
        let srcBytesPerRow = w * 8

        var srcData = Data(count: srcBytesPerRow * h)
        srcData.withUnsafeMutableBytes { raw in
            texture.getBytes(
                raw.baseAddress!,
                bytesPerRow: srcBytesPerRow,
                from: MTLRegion(
                    origin: MTLOrigin(x: 0, y: 0, z: 0),
                    size: MTLSize(width: w, height: h, depth: 1)
                ),
                mipmapLevel: 0
            )
        }

        guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
              let provider = CGDataProvider(data: srcData as CFData) else { return nil }

        let f16Bitmap: UInt32 =
            CGImageAlphaInfo.premultipliedLast.rawValue |
            CGBitmapInfo.floatComponents.rawValue |
            CGBitmapInfo.byteOrder16Little.rawValue

        guard let f16Image = CGImage(
            width: w, height: h,
            bitsPerComponent: 16, bitsPerPixel: 64,
            bytesPerRow: srcBytesPerRow,
            space: colorSpace,
            bitmapInfo: CGBitmapInfo(rawValue: f16Bitmap),
            provider: provider, decode: nil,
            shouldInterpolate: false, intent: .defaultIntent
        ) else { return nil }

        guard let ctx = CGContext(
            data: nil, width: w, height: h,
            bitsPerComponent: 8, bytesPerRow: w * 4,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        ctx.draw(f16Image, in: CGRect(x: 0, y: 0, width: w, height: h))
        return ctx.makeImage()
    }

    /// Crop the source CGImage to the selection's bounding box. Canvas coords
    /// are Y-up; the source CGImage is Y-down (row 0 = top).
    private static func maskedCrop(
        source: CGImage,
        path: CGPath,
        canvasSize: CGSize
    ) -> CGImage? {
        let H = canvasSize.height
        let bounds = path.boundingBoxOfPath.intersection(
            CGRect(x: 0, y: 0, width: canvasSize.width, height: canvasSize.height)
        )
        guard !bounds.isEmpty, bounds.width >= 1, bounds.height >= 1 else { return nil }

        let srcRect = CGRect(
            x: bounds.minX,
            y: H - bounds.maxY,
            width: bounds.width,
            height: bounds.height
        )
        return source.cropping(to: srcRect)
    }
}
