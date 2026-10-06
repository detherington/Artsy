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
///   │   ├── layer-0-height.png   (16-bit grey: paint thickness 0...8, only for layers that have any)
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
        /// Grid and guide lines; absent in documents from before they existed.
        var guides: CanvasGuides? = nil

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
        let started = DispatchTime.now().uptimeNanoseconds
        let layers = viewModel.layerStack?.layers.count ?? 0
        let size = "\(Int(viewModel.canvasSize.width))×\(Int(viewModel.canvasSize.height))"
        let logged: (Result<Void, Error>) -> Void = { result in
            switch result {
            case .success:
                DiagnosticsLog.shared.note(.document, String(format: "saved %@ (%@, %d layers) in %.2f s", url.lastPathComponent, size, layers,
                                                             Double(DispatchTime.now().uptimeNanoseconds - started) / 1e9))
            case .failure(let error):
                DiagnosticsLog.shared.error(error, doing: "saving \(url.lastPathComponent)")
            }
            completion(result)
        }
        do {
            try saveAsyncCore(renderer: renderer, viewModel: viewModel, to: url, completion: logged)
        } catch {
            DispatchQueue.main.async { logged(.failure(error)) }
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

        // Everything goes into a fresh bundle on the document's volume, which takes the
        // document's place only once all of it is there: a save that fails or is cut short
        // leaves the last one whole, and nothing from an earlier save lingers (a height
        // map of a layer since flattened, which would attach to whatever layer took its
        // place in the list).
        let fm = FileManager.default
        let stagingDir = try fm.url(for: .itemReplacementDirectory, in: .userDomainMask, appropriateFor: url, create: true)
        let bundleURL = stagingDir.appendingPathComponent(url.lastPathComponent)
        let layersDir = bundleURL.appendingPathComponent("layers")
        try fm.createDirectory(at: layersDir, withIntermediateDirectories: true)
        func discardStaging() { try? fm.removeItem(at: stagingDir) }

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
            activeLayerIndex: layerStack.activeLayerIndex,
            guides: viewModel.guides
        )
        let jsonData = try JSONEncoder().encode(doc)
        do {
            try jsonData.write(to: bundleURL.appendingPathComponent("document.json"))
        } catch {
            discardStaging()
            throw error
        }

        // 2. Allocate shared (CPU-readable) textures for every layer + composite,
        //    and run ALL GPU work in a single command buffer with a single wait.
        //    A layer that cannot be read back cannot be left out of the file.
        let textureManager = renderer.textureManager
        var readables: [MTLTexture] = []
        var heightReadables: [(index: Int, texture: MTLTexture)] = []
        let compositeReadable: MTLTexture
        let cmdBuf: MTLCommandBuffer
        do {
            readables.reserveCapacity(layerStack.layers.count)
            for layer in layerStack.layers {
                readables.append(try textureManager.makeSharedTexture(
                    width: layer.texture.width, height: layer.texture.height, label: "SaveLayer"
                ))
            }
            // Height maps, for the layers that have one
            for (i, layer) in layerStack.layers.enumerated() {
                guard let height = layer.heightTexture else { continue }
                heightReadables.append((i, try textureManager.makeHeightTexture(
                    width: height.width, height: height.height, label: "SaveHeight", shared: true
                )))
            }
            compositeReadable = try textureManager.makeSharedTexture(
                width: Int(viewModel.canvasSize.width), height: Int(viewModel.canvasSize.height), label: "SaveComposite"
            )
            guard let buffer = renderer.context.commandQueue.makeCommandBuffer() else { throw DocumentError.saveFailed }
            cmdBuf = buffer
        } catch {
            discardStaging()
            throw error
        }

        // The thumbnail: the layers as the canvas shows them, over white. Flattened into the
        // readable itself, so the live composite (and what is on screen) is left alone.
        textureManager.clearTexture(compositeReadable, commandBuffer: cmdBuf,
                                    color: MTLClearColor(red: 1, green: 1, blue: 1, alpha: 1))
        renderer.flattenLayers(onto: compositeReadable, commandBuffer: cmdBuf)

        // Single blit encoder with all copies batched.
        if let blit = cmdBuf.makeBlitCommandEncoder() {
            for (i, layer) in layerStack.layers.enumerated() {
                blit.copy(from: layer.texture, to: readables[i])
            }
            for (i, readable) in heightReadables {
                blit.copy(from: layerStack.layers[i].heightTexture!, to: readable)
            }
            #if !arch(arm64)
            for readable in readables + heightReadables.map(\.texture) + [compositeReadable] {
                blit.synchronize(resource: readable)
            }
            #endif
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
                    discardStaging()
                    DispatchQueue.main.async { completion(.failure(firstError)) }
                    return
                }
                for (i, readable) in heightReadables {
                    do {
                        try writeHeightPNG(readable, to: layersDir.appendingPathComponent("layer-\(i)-height.png"))
                    } catch {
                        discardStaging()
                        DispatchQueue.main.async { completion(.failure(error)) }
                        return
                    }
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

                // 4. All of it is there: it takes the document's place
                do {
                    if fm.fileExists(atPath: url.path) {
                        _ = try fm.replaceItemAt(url, withItemAt: bundleURL, backupItemName: nil, options: [])
                    } else {
                        try fm.moveItem(at: bundleURL, to: url)
                    }
                } catch {
                    discardStaging()
                    DispatchQueue.main.async { completion(.failure(error)) }
                    return
                }
                try? fm.removeItem(at: stagingDir)
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
        let started = DispatchTime.now().uptimeNanoseconds

        guard fm.fileExists(atPath: docURL.path) else {
            throw DocumentError.invalidFormat
        }

        let jsonData = try Data(contentsOf: docURL)
        let doc = try JSONDecoder().decode(DocumentData.self, from: jsonData)
        guard (1...LayerStack.maxCanvasSide).contains(doc.canvasWidth),
              (1...LayerStack.maxCanvasSide).contains(doc.canvasHeight) else {
            throw DocumentError.invalidFormat
        }

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
            // A new texture holds whatever its memory held before; a layer whose file is
            // missing must still be empty. Committed before the file's pixels go in.
            if let clear = metalContext.commandQueue.makeCommandBuffer() {
                textureManager.clearTexture(texture, commandBuffer: clear)
                clear.commit()
            }

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
            if fm.fileExists(atPath: layerFile.path) {
                loadLayerPNG(from: layerFile, into: texture, context: metalContext)
            }

            // And its thickness, if it was saved with any
            let heightFile = layersDir.appendingPathComponent("layer-\(i)-height.png")
            if fm.fileExists(atPath: heightFile.path) {
                layer.heightTexture = loadHeightPNG(from: heightFile, width: doc.canvasWidth, height: doc.canvasHeight,
                                                    textureManager: textureManager, context: metalContext)
            }

            layerStack.layers.append(layer)
        }

        if doc.activeLayerIndex < layerStack.layers.count {
            layerStack.activeLayerIndex = doc.activeLayerIndex
        }
        if let guides = doc.guides { viewModel.guides = guides }

        DiagnosticsLog.shared.note(.document, String(format: "opened %@ (%d×%d, %d layers, %d with thickness) in %.2f s",
                                                     url.lastPathComponent, doc.canvasWidth, doc.canvasHeight, layerStack.layers.count,
                                                     layerStack.layers.filter { $0.heightTexture != nil }.count,
                                                     Double(DispatchTime.now().uptimeNanoseconds - started) / 1e9))
        return (viewModel, canvasView)
    }

    /// A layer's own PNG into its texture. Its pixels are the canvas's Display P3 components
    /// as they were saved, whatever profile the file carries (files from before the
    /// profile was right say sRGB), so they are taken as they are, not converted.
    private static func loadLayerPNG(from url: URL, into texture: MTLTexture, context: MetalContext) {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return }
        let asP3 = CGColorSpace(name: CGColorSpace.displayP3).flatMap { image.copy(colorSpace: $0) } ?? image
        loadCGImageIntoTexture(cgImage: asP3, texture: texture, context: context)
    }

    // MARK: - Height maps

    /// Thickness this high is stored as full white; paint is rarely piled past 2 or 3.
    private static let heightFileScale: Float = 8

    /// Write a CPU-readable height map as a 16-bit grey PNG, thickness 0...8 as 0...65535.
    private static func writeHeightPNG(_ texture: MTLTexture, to url: URL) throws {
        let w = texture.width, h = texture.height
        var half = [UInt16](repeating: 0, count: w * h)
        half.withUnsafeMutableBytes {
            texture.getBytes($0.baseAddress!, bytesPerRow: w * 2,
                             from: MTLRegion(origin: MTLOrigin(x: 0, y: 0, z: 0), size: MTLSize(width: w, height: h, depth: 1)),
                             mipmapLevel: 0)
        }
        let grey: [UInt16] = half.map {
            UInt16((max(0, min(1, Float(Float16(bitPattern: $0)) / heightFileScale)) * 65535).rounded())
        }
        let data = grey.withUnsafeBufferPointer { Data(buffer: $0) }
        guard let provider = CGDataProvider(data: data as CFData),
              let image = CGImage(
                width: w, height: h, bitsPerComponent: 16, bitsPerPixel: 16, bytesPerRow: w * 2,
                space: CGColorSpaceCreateDeviceGray(),
                bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue | CGBitmapInfo.byteOrder16Little.rawValue),
                provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent
              ) else { throw DocumentError.loadFailed }
        try writeCGImageAsPNG(image, to: url)
    }

    /// Read a height map written by `writeHeightPNG` into a new height texture.
    private static func loadHeightPNG(from url: URL, width: Int, height: Int, textureManager: TextureManager,
                                      context: MetalContext) -> MTLTexture? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil),
              let ctx = CGContext(
                data: nil, width: width, height: height, bitsPerComponent: 16, bytesPerRow: width * 2,
                space: CGColorSpaceCreateDeviceGray(),
                bitmapInfo: CGImageAlphaInfo.none.rawValue | CGBitmapInfo.byteOrder16Little.rawValue
              ) else { return nil }
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        guard let data = ctx.data else { return nil }
        let grey = data.assumingMemoryBound(to: UInt16.self)
        var half = [UInt16](repeating: 0, count: width * height)
        for i in 0..<(width * height) {
            half[i] = Float16(Float(grey[i]) / 65535 * heightFileScale).bitPattern
        }

        guard let staging = try? textureManager.makeHeightTexture(width: width, height: height, label: "HeightStaging", shared: true),
              let texture = try? textureManager.makeHeightTexture(width: width, height: height, label: "Height") else { return nil }
        half.withUnsafeBytes {
            staging.replace(region: MTLRegion(origin: MTLOrigin(x: 0, y: 0, z: 0), size: MTLSize(width: width, height: height, depth: 1)),
                            mipmapLevel: 0, withBytes: $0.baseAddress!, bytesPerRow: width * 2)
        }
        guard let cmdBuf = context.commandQueue.makeCommandBuffer(),
              let blit = cmdBuf.makeBlitCommandEncoder() else { return nil }
        blit.copy(from: staging, to: texture)
        blit.endEncoding()
        cmdBuf.commit()
        return texture
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

        guard let colorSpace = CGColorSpace(name: CGColorSpace.displayP3),
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
        guard let colorSpace = CGColorSpace(name: CGColorSpace.displayP3),
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
    /// Draw `cgImage` over the whole of `texture`, converted into the canvas's colour space
    /// (Display P3) from whatever the image is in.
    static func loadCGImageIntoTexture(cgImage: CGImage, texture: MTLTexture, context: MetalContext) {
        let width = texture.width
        let height = texture.height

        guard let colorSpace = CGColorSpace(name: CGColorSpace.displayP3),
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

    /// Public alias so other callers (e.g. CanvasView's paste fast path) can
    /// share the same precomputed table.
    static let u8ToF16LUTPublic: [UInt16] = u8ToF16LUT

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

}

enum DocumentError: LocalizedError {
    case noLayers
    case invalidFormat
    case loadFailed
    case saveFailed

    var errorDescription: String? {
        switch self {
        case .noLayers: return "No layers to save"
        case .invalidFormat: return "Not a valid .artsy file"
        case .loadFailed: return "Failed to load document"
        case .saveFailed: return "Failed to save document"
        }
    }
}
