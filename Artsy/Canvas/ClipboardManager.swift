import Foundation
import Metal
import AppKit
import CoreGraphics

/// Cut / Copy / Paste for canvas pixels.
///
/// Copy runs asynchronously: main thread kicks off a GPU blit, and the
/// CPU-side F16→U8 conversion + PNG/TIFF encoding + pasteboard write
/// all happen on a background queue once the GPU completes. The main
/// thread never blocks.
///
/// Copy also stamps the source's canvas-space origin onto the pasteboard
/// under a private type (`com.artsy.paste-origin`). On paste, if this
/// metadata is present, the caller can use it to position the paste at
/// its original location ("paste in place") instead of the default
/// centered placement.
enum ClipboardManager {

    /// Private pasteboard type carrying the canvas-space bottom-left origin
    /// (Y-up) of the copied region. Only Artsy writes this; readers that
    /// don't understand it ignore it.
    static let originType = NSPasteboard.PasteboardType("com.artsy.paste-origin")

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

        // Canvas-space (Y-up) origin of the source region. For a selection
        // it's the bounding-box bottom-left; for a whole-layer copy it's (0,0).
        let origin: CGPoint = {
            if let path = selectionPath {
                let b = path.boundingBoxOfPath
                return CGPoint(x: b.minX, y: b.minY)
            }
            return .zero
        }()

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
                writeImageToPasteboard(finalImage, origin: origin)
            }
        }
        cmdBuf.commit()
    }

    /// Read the canvas-space origin (Y-up) written by a previous Artsy copy,
    /// if present on the pasteboard. Returns nil for content copied from
    /// other apps.
    static func readOrigin() -> CGPoint? {
        guard let data = NSPasteboard.general.data(forType: originType),
              let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Double],
              let x = dict["x"], let y = dict["y"] else { return nil }
        return CGPoint(x: x, y: y)
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

    private static func writeImageToPasteboard(_ cgImage: CGImage, origin: CGPoint) {
        let pngData = NSMutableData()
        if let dest = CGImageDestinationCreateWithData(
            pngData, "public.png" as CFString, 1, nil
        ) {
            CGImageDestinationAddImage(dest, cgImage, nil)
            CGImageDestinationFinalize(dest)
        }

        let tiffData = NSMutableData()
        if let dest = CGImageDestinationCreateWithData(
            tiffData, "public.tiff" as CFString, 1, nil
        ) {
            CGImageDestinationAddImage(dest, cgImage, nil)
            CGImageDestinationFinalize(dest)
        }

        // Serialize origin as tiny JSON payload for our private pasteboard type.
        let originData = try? JSONSerialization.data(withJSONObject: [
            "x": Double(origin.x),
            "y": Double(origin.y)
        ])

        DispatchQueue.main.async {
            let pb = NSPasteboard.general
            pb.clearContents()
            if pngData.length > 0  { pb.setData(pngData as Data,  forType: .png)  }
            if tiffData.length > 0 { pb.setData(tiffData as Data, forType: .tiff) }
            if let originData = originData {
                pb.setData(originData, forType: originType)
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

    /// Crop the source CGImage to the selection's bounding box AND mask out
    /// pixels outside the path (they become transparent). Produces a
    /// shape-accurate copy for ellipse / freeform selections.
    ///
    /// Coord systems:
    ///   - `path` and `canvasSize` are in canvas coords (Y-up, origin at
    ///     canvas bottom-left)
    ///   - `source` is a Y-down CGImage (row 0 = top, matching the Metal
    ///     texture it came from)
    ///   - The CGContext we build is default (Y-up user space), so canvas
    ///     coords map into it with just a translation — no Y-flip needed
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

        // Source crop rect in Y-down texture coords.
        let srcRect = CGRect(
            x: bounds.minX,
            y: H - bounds.maxY,
            width: bounds.width,
            height: bounds.height
        )
        guard let sub = source.cropping(to: srcRect) else { return nil }

        let outW = Int(bounds.width.rounded())
        let outH = Int(bounds.height.rounded())

        guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = CGContext(
                data: nil,
                width: outW, height: outH,
                bitsPerComponent: 8, bytesPerRow: outW * 4,
                space: colorSpace,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              ) else {
            // Clip setup failed — fall back to the rectangular bbox crop.
            return sub
        }

        // Translate the canvas-space path so its bounding box origin lines up
        // with the output context's user-space origin (0, 0). Canvas Y-up
        // matches the CGContext's default Y-up user space, so no Y-flip.
        var pathTransform = CGAffineTransform(translationX: -bounds.minX, y: -bounds.minY)
        guard let clippedPath = path.copy(using: &pathTransform) else {
            return sub
        }

        ctx.addPath(clippedPath)
        ctx.clip()
        ctx.draw(sub, in: CGRect(x: 0, y: 0, width: outW, height: outH))
        return ctx.makeImage() ?? sub
    }
}
