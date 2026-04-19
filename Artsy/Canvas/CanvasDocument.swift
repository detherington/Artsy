import Foundation
import AppKit
import Metal
import Accelerate
import ImageIO
import UniformTypeIdentifiers

/// Handles save/load of .artsy bundle format.
/// Bundle structure:
///   MyDrawing.artsy/
///   ├── document.json    (metadata, canvas size, layer info)
///   ├── layers/
///   │   ├── layer-0.png
///   │   ├── layer-1.png
///   │   └── ...
///   └── thumbnail.png
final class CanvasDocument {

    struct DocumentData: Codable {
        let version: Int
        let canvasWidth: Int
        let canvasHeight: Int
        let layers: [LayerInfo]
        let activeLayerIndex: Int

        struct LayerInfo: Codable {
            let id: String
            let name: String
            let isVisible: Bool
            let isLocked: Bool
            let opacity: Float
            let blendMode: String
        }
    }

    // MARK: - Save

    /// Non-blocking save — returns immediately after kicking off GPU work.
    /// All heavy CPU/IO happens on a background thread after the GPU completes.
    /// `completion` is dispatched on the main queue.
    static func saveAsync(
        renderer: CanvasRenderer,
        viewModel: CanvasViewModel,
        to url: URL,
        completion: @escaping (Result<Void, Error>) -> Void
    ) {
        do {
            try saveAsyncCore(renderer: renderer, viewModel: viewModel, to: url, completion: completion)
        } catch {
            DispatchQueue.main.async { completion(.failure(error)) }
        }
    }

    private static func saveAsyncCore(
        renderer: CanvasRenderer,
        viewModel: CanvasViewModel,
        to url: URL,
        completion: @escaping (Result<Void, Error>) -> Void
    ) throws {
        guard let layerStack = viewModel.layerStack else {
            throw DocumentError.noLayers
        }

        let bundleURL = url
        let fm = FileManager.default
        try fm.createDirectory(at: bundleURL, withIntermediateDirectories: true)
        let layersDir = bundleURL.appendingPathComponent("layers")
        try fm.createDirectory(at: layersDir, withIntermediateDirectories: true)

        // 1. Write JSON metadata (tiny, synchronous)
        let layerInfos: [DocumentData.LayerInfo] = layerStack.layers.map { layer in
            DocumentData.LayerInfo(
                id: layer.id.uuidString,
                name: layer.name,
                isVisible: layer.isVisible,
                isLocked: layer.isLocked,
                opacity: layer.opacity,
                blendMode: layer.blendMode.rawValue
            )
        }
        let doc = DocumentData(
            version: 1,
            canvasWidth: Int(viewModel.canvasSize.width),
            canvasHeight: Int(viewModel.canvasSize.height),
            layers: layerInfos,
            activeLayerIndex: layerStack.activeLayerIndex
        )
        let jsonData = try JSONEncoder().encode(doc)
        try jsonData.write(to: bundleURL.appendingPathComponent("document.json"))

        // 2. Allocate shared (CPU-readable) textures for every layer + composite,
        //    and run ALL GPU work in a single command buffer with a single wait.
        let textureManager = renderer.textureManager
        var readables: [MTLTexture] = []
        readables.reserveCapacity(layerStack.layers.count)
        for layer in layerStack.layers {
            guard let t = try? textureManager.makeSharedTexture(
                width: layer.texture.width,
                height: layer.texture.height,
                label: "SaveLayer"
            ) else { continue }
            readables.append(t)
        }

        guard let composite = renderer.compositeTexture,
              let compositeReadable = try? textureManager.makeSharedTexture(
                width: composite.width, height: composite.height, label: "SaveComposite"
              ),
              let cmdBuf = renderer.context.commandQueue.makeCommandBuffer() else {
            throw DocumentError.loadFailed
        }

        // Re-composite into the renderer's composite texture (reflects current state).
        textureManager.clearTexture(composite, commandBuffer: cmdBuf,
                                    color: MTLClearColor(red: 1, green: 1, blue: 1, alpha: 1))
        for layer in layerStack.layers where layer.isVisible {
            renderer.compositor.compositeNormal(
                source: layer.texture, onto: composite,
                opacity: layer.opacity, commandBuffer: cmdBuf
            )
        }

        // Single blit encoder with all copies batched.
        if let blit = cmdBuf.makeBlitCommandEncoder() {
            for (i, layer) in layerStack.layers.enumerated() where i < readables.count {
                blit.copy(from: layer.texture, to: readables[i])
            }
            blit.copy(from: composite, to: compositeReadable)
            blit.endEncoding()
        }

        // 3. When the GPU finishes, all shared textures are CPU-readable. Do the heavy
        //    CPU + IO work on a background queue so main stays responsive.
        let layerURLs: [URL] = (0..<readables.count).map {
            layersDir.appendingPathComponent("layer-\($0).png")
        }
        let thumbnailURL = bundleURL.appendingPathComponent("thumbnail.png")

        cmdBuf.addCompletedHandler { _ in
            DispatchQueue.global(qos: .userInitiated).async {
                var parallelErrors: [Error?] = Array(repeating: nil, count: readables.count)
                DispatchQueue.concurrentPerform(iterations: readables.count) { i in
                    do {
                        guard let cg = makeCGImageFromF16Texture(readables[i]) else {
                            throw DocumentError.loadFailed
                        }
                        try writeCGImageAsPNG(cg, to: layerURLs[i])
                    } catch {
                        parallelErrors[i] = error
                    }
                }
                if let firstError = parallelErrors.compactMap({ $0 }).first {
                    DispatchQueue.main.async { completion(.failure(firstError)) }
                    return
                }

                // Thumbnail
                if let compositeCG = makeCGImageFromF16Texture(compositeReadable) {
                    let tw = compositeReadable.width, th = compositeReadable.height
                    let maxSize = 512
                    let scale = min(Double(maxSize) / Double(tw), Double(maxSize) / Double(th), 1.0)
                    let scaledW = max(1, Int(Double(tw) * scale))
                    let scaledH = max(1, Int(Double(th) * scale))
                    let scaled = (scaledW == tw && scaledH == th)
                        ? compositeCG
                        : (scaleCGImage(compositeCG, to: CGSize(width: scaledW, height: scaledH)) ?? compositeCG)
                    try? writeCGImageAsPNG(scaled, to: thumbnailURL)
                }

                DispatchQueue.main.async { completion(.success(())) }
            }
        }
        cmdBuf.commit()
    }

    // MARK: - Load

    static func load(
        from url: URL,
        metalContext: MetalContext
    ) throws -> (viewModel: CanvasViewModel, canvasView: CanvasView) {
        let fm = FileManager.default
        let docURL = url.appendingPathComponent("document.json")

        guard fm.fileExists(atPath: docURL.path) else {
            throw DocumentError.invalidFormat
        }

        let jsonData = try Data(contentsOf: docURL)
        let doc = try JSONDecoder().decode(DocumentData.self, from: jsonData)

        let canvasSize = CGSize(width: doc.canvasWidth, height: doc.canvasHeight)
        let viewModel = CanvasViewModel(canvasSize: canvasSize)

        let canvasView = CanvasView(
            frame: NSRect(x: 0, y: 0, width: 800, height: 600),
            device: metalContext.device
        )
        try canvasView.configure(context: metalContext, viewModel: viewModel)

        guard let layerStack = viewModel.layerStack else {
            throw DocumentError.loadFailed
        }

        // Clear default layers directly
        layerStack.layers.removeAll()
        layerStack.activeLayerIndex = 0

        let textureManager = TextureManager(device: metalContext.device)

        // Load layers from PNGs
        let layersDir = url.appendingPathComponent("layers")
        for (i, layerInfo) in doc.layers.enumerated() {
            // Create layer texture
            guard let texture = try? textureManager.makeCanvasTexture(
                width: doc.canvasWidth, height: doc.canvasHeight, label: layerInfo.name
            ) else { continue }

            let layer = Layer(
                id: UUID(uuidString: layerInfo.id) ?? UUID(),
                name: layerInfo.name,
                texture: texture
            )
            layer.isVisible = layerInfo.isVisible
            layer.isLocked = layerInfo.isLocked
            layer.opacity = layerInfo.opacity
            layer.blendMode = LayerBlendMode(rawValue: layerInfo.blendMode) ?? .normal

            // Load PNG into the layer's texture
            let layerFile = layersDir.appendingPathComponent("layer-\(i).png")
            if fm.fileExists(atPath: layerFile.path),
               let pngData = try? Data(contentsOf: layerFile),
               let nsImage = NSImage(data: pngData),
               let cgImage = nsImage.cgImage(forProposedRect: nil, context: nil, hints: nil) {
                loadCGImageIntoTexture(cgImage: cgImage, texture: texture, context: metalContext)
            }

            layerStack.layers.append(layer)
        }

        if doc.activeLayerIndex < layerStack.layers.count {
            layerStack.activeLayerIndex = doc.activeLayerIndex
        }

        return (viewModel, canvasView)
    }

    // MARK: - Fast save helpers

    /// Build an 8-bit RGBA CGImage from a rgba16Float MTLTexture. Uses CoreGraphics to
    /// do the F16→U8 conversion, which is SIMD-optimized internally and much faster than
    /// the scalar Swift loop. Returns nil on allocation failure.
    private static func makeCGImageFromF16Texture(_ texture: MTLTexture) -> CGImage? {
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
              let provider = CGDataProvider(data: srcData as CFData) else {
            return nil
        }

        // Describe the F16 source bitmap
        let f16BitmapInfo: UInt32 =
            CGImageAlphaInfo.premultipliedLast.rawValue |
            CGBitmapInfo.floatComponents.rawValue |
            CGBitmapInfo.byteOrder16Little.rawValue
        guard let f16Image = CGImage(
            width: w, height: h,
            bitsPerComponent: 16, bitsPerPixel: 64,
            bytesPerRow: srcBytesPerRow,
            space: colorSpace,
            bitmapInfo: CGBitmapInfo(rawValue: f16BitmapInfo),
            provider: provider, decode: nil,
            shouldInterpolate: false, intent: .defaultIntent
        ) else { return nil }

        // Render into an 8-bit RGBA context (CoreGraphics handles the conversion with SIMD).
        guard let ctx = CGContext(
            data: nil, width: w, height: h,
            bitsPerComponent: 8, bytesPerRow: w * 4,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        ctx.draw(f16Image, in: CGRect(x: 0, y: 0, width: w, height: h))
        return ctx.makeImage()
    }

    /// Write an 8-bit RGBA CGImage as PNG using ImageIO (faster than NSBitmapImageRep).
    private static func writeCGImageAsPNG(_ cgImage: CGImage, to url: URL) throws {
        let type = UTType.png.identifier as CFString
        guard let dest = CGImageDestinationCreateWithURL(url as CFURL, type, 1, nil) else {
            throw DocumentError.loadFailed
        }
        CGImageDestinationAddImage(dest, cgImage, nil)
        if !CGImageDestinationFinalize(dest) {
            throw DocumentError.loadFailed
        }
    }

    /// Scale a CGImage to a new size via CoreGraphics.
    private static func scaleCGImage(_ image: CGImage, to size: CGSize) -> CGImage? {
        let w = Int(size.width), h = Int(size.height)
        guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = CGContext(
                data: nil, width: w, height: h,
                bitsPerComponent: 8, bytesPerRow: w * 4,
                space: colorSpace,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              ) else { return nil }
        ctx.interpolationQuality = .high
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        return ctx.makeImage()
    }

    /// High-quality downscale of RGBA8 pixels via vImage.
    private static func scaleRGBA8(
        _ src: Data, srcWidth: Int, srcHeight: Int,
        dstWidth: Int, dstHeight: Int
    ) -> Data {
        if srcWidth == dstWidth && srcHeight == dstHeight { return src }
        var srcMutable = src
        var dst = Data(count: dstWidth * dstHeight * 4)
        srcMutable.withUnsafeMutableBytes { srcRaw in
            dst.withUnsafeMutableBytes { dstRaw in
                var srcBuf = vImage_Buffer(
                    data: srcRaw.baseAddress!,
                    height: vImagePixelCount(srcHeight),
                    width: vImagePixelCount(srcWidth),
                    rowBytes: srcWidth * 4
                )
                var dstBuf = vImage_Buffer(
                    data: dstRaw.baseAddress!,
                    height: vImagePixelCount(dstHeight),
                    width: vImagePixelCount(dstWidth),
                    rowBytes: dstWidth * 4
                )
                vImageScale_ARGB8888(&srcBuf, &dstBuf, nil, vImage_Flags(kvImageHighQualityResampling))
            }
        }
        return dst
    }

    /// Write RGBA8 bytes as PNG via ImageIO (faster + less memory copying than NSBitmapImageRep).
    private static func writeRGBA8PNG(_ rgba8: Data, width: Int, height: Int, to url: URL) throws {
        guard let provider = CGDataProvider(data: rgba8 as CFData),
              let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) else {
            throw DocumentError.loadFailed
        }
        let bitmapInfo = CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue)
        guard let cgImage = CGImage(
            width: width, height: height,
            bitsPerComponent: 8, bitsPerPixel: 32,
            bytesPerRow: width * 4,
            space: colorSpace,
            bitmapInfo: bitmapInfo,
            provider: provider,
            decode: nil,
            shouldInterpolate: false,
            intent: .defaultIntent
        ) else { throw DocumentError.loadFailed }

        let type = UTType.png.identifier as CFString
        guard let dest = CGImageDestinationCreateWithURL(url as CFURL, type, 1, nil) else {
            throw DocumentError.loadFailed
        }
        CGImageDestinationAddImage(dest, cgImage, nil)
        if !CGImageDestinationFinalize(dest) {
            throw DocumentError.loadFailed
        }
    }

    // MARK: - Legacy helpers (kept for thumbnail fallback path reference)

    private static func textureToRGBA8PNG(texture: MTLTexture, renderer: CanvasRenderer) -> Data? {
        let width = texture.width
        let height = texture.height

        guard let readableTexture = try? renderer.textureManager.makeSharedTexture(
            width: width, height: height, label: "Export"
        ) else { return nil }

        guard let commandBuffer = renderer.context.commandQueue.makeCommandBuffer(),
              let blitEncoder = commandBuffer.makeBlitCommandEncoder() else { return nil }

        blitEncoder.copy(from: texture, to: readableTexture)
        blitEncoder.endEncoding()
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()

        // Read float16 pixels
        let bytesPerPixel = 8
        let bytesPerRow = width * bytesPerPixel
        var pixelData = [UInt8](repeating: 0, count: height * bytesPerRow)
        readableTexture.getBytes(&pixelData, bytesPerRow: bytesPerRow,
            from: MTLRegion(origin: .init(x: 0, y: 0, z: 0), size: .init(width: width, height: height, depth: 1)),
            mipmapLevel: 0)

        // Convert to RGBA8
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
        return rep.representation(using: .png, properties: [:])
    }

    private static func generateThumbnail(renderer: CanvasRenderer, maxSize: Int) -> Data? {
        guard let composite = renderer.compositeTexture else { return nil }

        // Re-composite to get current state
        guard let commandBuffer = renderer.context.commandQueue.makeCommandBuffer() else { return nil }
        renderer.textureManager.clearTexture(composite, commandBuffer: commandBuffer,
            color: MTLClearColor(red: 1, green: 1, blue: 1, alpha: 1))
        if let viewModel = renderer.viewModel, let layerStack = viewModel.layerStack {
            for layer in layerStack.layers where layer.isVisible {
                renderer.compositor.compositeNormal(
                    source: layer.texture, onto: composite,
                    opacity: layer.opacity, commandBuffer: commandBuffer)
            }
        }
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()

        guard let fullPNG = textureToRGBA8PNG(texture: composite, renderer: renderer),
              let nsImage = NSImage(data: fullPNG) else { return nil }

        // Scale down
        let w = nsImage.size.width
        let h = nsImage.size.height
        let scale = min(CGFloat(maxSize) / w, CGFloat(maxSize) / h, 1.0)
        let thumbSize = NSSize(width: w * scale, height: h * scale)

        let thumb = NSImage(size: thumbSize)
        thumb.lockFocus()
        nsImage.draw(in: NSRect(origin: .zero, size: thumbSize))
        thumb.unlockFocus()

        guard let tiffData = thumb.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiffData) else { return nil }
        return rep.representation(using: .png, properties: [:])
    }

    static func loadCGImageIntoTexture(cgImage: CGImage, texture: MTLTexture, context: MetalContext) {
        let width = texture.width
        let height = texture.height

        guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = CGContext(data: nil, width: width, height: height,
                                 bitsPerComponent: 8, bytesPerRow: width * 4,
                                 space: colorSpace,
                                 bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return }

        ctx.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))

        guard let data = ctx.data else { return }
        let rgba8 = data.assumingMemoryBound(to: UInt8.self)

        // RGBA8 → RGBA16Float via 256-entry LUT (unsafe pointer loop, no
        // bounds checks, ~10x faster than the per-pixel floatToFloat16 call).
        let pixelCount = width * height
        var float16Data = [UInt16](repeating: 0, count: pixelCount * 4)
        let lut = Self.u8ToF16LUT
        float16Data.withUnsafeMutableBufferPointer { dstBuf in
            let dst = dstBuf.baseAddress!
            let total = pixelCount * 4
            var i = 0
            while i < total {
                dst[i]     = lut[Int(rgba8[i])]
                dst[i + 1] = lut[Int(rgba8[i + 1])]
                dst[i + 2] = lut[Int(rgba8[i + 2])]
                dst[i + 3] = lut[Int(rgba8[i + 3])]
                i += 4
            }
        }

        // Upload to a shared texture first, then blit to the private one
        guard let staging = try? TextureManager(device: context.device).makeSharedTexture(
            width: width, height: height, label: "Staging"
        ) else { return }

        float16Data.withUnsafeBytes { raw in
            staging.replace(
                region: MTLRegion(origin: .init(x: 0, y: 0, z: 0),
                                  size: .init(width: width, height: height, depth: 1)),
                mipmapLevel: 0,
                withBytes: raw.baseAddress!,
                bytesPerRow: width * 8
            )
        }

        guard let cmdBuf = context.commandQueue.makeCommandBuffer(),
              let blit = cmdBuf.makeBlitCommandEncoder() else { return }
        blit.copy(from: staging, to: texture)
        blit.endEncoding()
        cmdBuf.commit()
        // No waitUntilCompleted — the renderer picks up the new texture content
        // on its next frame, and Metal serializes ordering automatically.
    }

    /// 256-entry lookup table: u8 value → corresponding half-float bits (for 0–1 range).
    /// Used by loadCGImageIntoTexture to avoid per-pixel float conversion.
    private static let u8ToF16LUT: [UInt16] = (0...255).map { floatToFloat16(Float($0) / 255.0) }

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

    private static func floatToFloat16(_ f: Float) -> UInt16 {
        let bits = f.bitPattern
        let sign = (bits >> 31) & 0x1
        let exp = Int((bits >> 23) & 0xFF) - 127
        let mant = bits & 0x7FFFFF

        if exp > 15 { return UInt16(sign << 15 | 0x1F << 10) } // inf
        if exp < -14 { return UInt16(sign << 15) }              // zero
        let hExp = UInt16(exp + 15)
        let hMant = UInt16(mant >> 13)
        return UInt16(sign << 15) | (hExp << 10) | hMant
    }

    private static func clampByte(_ f: Float) -> UInt8 {
        UInt8(max(0, min(255, f * 255)))
    }
}

enum DocumentError: LocalizedError {
    case noLayers
    case invalidFormat
    case loadFailed

    var errorDescription: String? {
        switch self {
        case .noLayers: return "No layers to save"
        case .invalidFormat: return "Not a valid .artsy file"
        case .loadFailed: return "Failed to load document"
        }
    }
}
