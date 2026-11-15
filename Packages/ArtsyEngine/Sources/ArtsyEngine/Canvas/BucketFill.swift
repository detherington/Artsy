import Foundation
import Metal
import CoreGraphics
import Foundation
import CoreGraphics
import os.log

/// CPU scanline flood fill for a layer's rgba16Float texture.
///
/// Operates directly on the native F16 texture bytes — no intermediate U8 conversion.
/// Main thread stays fully responsive; all heavy work runs on a background queue
/// triggered by the GPU's `addCompletedHandler`. The fill lands through a mask of the
/// pixels it reached, so whatever was painted elsewhere on the layer while it ran stays.
public enum BucketFill {

    private static let log = OSLog(subsystem: "com.artsy.app", category: "BucketFill")

    /// What a fill found: the pixels it reached, as a mask the size of their bounding box.
    public struct Result {
        let origin: (x: Int, y: Int)
        let width: Int, height: Int
        let mask: [UInt8]
    }

    /// - Parameter source: what the fill reads to find its region, if not the layer it
    ///   fills: the picture as it looks (the composite), or the reference layer (the inks).
    /// - Parameter closingGaps: pixels: a break in the lines up to twice as wide holds.
    /// - Parameter spread: pixels the fill grows past its region, under the lines.
    /// - Parameter keepingAlpha: the layer's alpha is locked: the fill colours only what is there.
    /// - Parameter shouldApply: asked on the main thread when the fill is ready to land,
    ///   seconds later on a big canvas; false if the undo step it was given has been undone
    ///   meanwhile, or its layer is gone.
    public static func fillAsync(
        renderer: CanvasRenderer,
        layer: Layer,
        reading source: MTLTexture? = nil,
        canvasPoint: CGPoint,
        canvasSize: CGSize,
        fillColor: StrokeColor,
        tolerance: Int,
        selectionPath: CGPath?,
        closingGaps: Int = 0,
        spread: Int = 0,
        keepingAlpha: Bool = false,
        shouldApply: @escaping () -> Bool = { true },
        onComplete: @escaping () -> Void
    ) {
        let width = layer.texture.width
        let height = layer.texture.height
        let read = source ?? layer.texture

        // Canvas coords are Y-up; textures are Y-down. Flip.
        let sx = Int(canvasPoint.x.rounded())
        let sy = Int((canvasSize.height - canvasPoint.y).rounded())
        guard sx >= 0, sx < width, sy >= 0, sy < height, read.width == width, read.height == height,
              read.pixelFormat == .rgba16Float else {
            onComplete()
            return
        }

        guard let staging = try? renderer.textureManager.makeSharedTexture(
            width: width, height: height, label: "BucketStaging"
        ),
        let cmdBuf = renderer.context.commandQueue.makeCommandBuffer(),
        let blit = cmdBuf.makeBlitCommandEncoder() else {
            onComplete()
            return
        }
        // The top level only: the composite keeps smaller levels of its own elsewhere
        blit.copy(from: read, sourceSlice: 0, sourceLevel: 0, sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0),
                  sourceSize: MTLSize(width: width, height: height, depth: 1),
                  to: staging, destinationSlice: 0, destinationLevel: 0, destinationOrigin: MTLOrigin(x: 0, y: 0, z: 0))
        blit.endEncoding()

        let context = renderer.context
        let targetTexture = layer.texture
        let readsOwnLayer = source == nil || source === layer.texture

        cmdBuf.addCompletedHandler { _ in
            DispatchQueue.global(qos: .userInitiated).async {
                let result = performFill(
                    staging: staging,
                    startX: sx, startY: sy,
                    width: width, height: height,
                    fillColor: fillColor,
                    tolerance: tolerance,
                    selectionPath: selectionPath,
                    readsOwnLayer: readsOwnLayer,
                    closingGaps: closingGaps,
                    spread: spread
                )
                DispatchQueue.main.async {
                    if let result, shouldApply() {
                        apply(result, color: fillColor, to: targetTexture, keepingAlpha: keepingAlpha, context: context)
                    }
                    onComplete()
                }
            }
        }
        cmdBuf.commit()
    }

    /// Write the fill's colour where its mask says, and nowhere else; on a layer whose
    /// alpha is locked, at each pixel's own alpha.
    public static func apply(_ result: Result, color: StrokeColor, to target: MTLTexture, keepingAlpha: Bool = false,
                             context: MetalContext) {
        let desc = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .r8Unorm, width: result.width,
                                                            height: result.height, mipmapped: false)
        desc.usage = .shaderRead
        desc.storageMode = .shared
        guard let mask = context.device.makeTexture(descriptor: desc),
              let commandBuffer = context.commandQueue.makeCommandBuffer(),
              let encoder = commandBuffer.makeComputeCommandEncoder() else { return }
        result.mask.withUnsafeBytes {
            mask.replace(region: MTLRegion(origin: MTLOrigin(x: 0, y: 0, z: 0),
                                           size: MTLSize(width: result.width, height: result.height, depth: 1)),
                         mipmapLevel: 0, withBytes: $0.baseAddress!, bytesPerRow: result.width)
        }
        var colour = SIMD4<Float>(color.red, color.green, color.blue, color.alpha)
        var origin = SIMD2<UInt32>(UInt32(result.origin.x), UInt32(result.origin.y))
        encoder.setComputePipelineState(keepingAlpha ? context.maskedFillKeepAlphaPipelineState : context.maskedFillPipelineState)
        encoder.setTexture(target, index: 0)
        encoder.setTexture(mask, index: 1)
        encoder.setBytes(&colour, length: MemoryLayout<SIMD4<Float>>.size, index: 0)
        encoder.setBytes(&origin, length: MemoryLayout<SIMD2<UInt32>>.size, index: 1)
        let group = MTLSize(width: 16, height: 16, depth: 1)
        encoder.dispatchThreadgroups(MTLSize(width: (result.width + 15) / 16, height: (result.height + 15) / 16, depth: 1),
                                     threadsPerThreadgroup: group)
        encoder.endEncoding()
        commandBuffer.commit()
    }

    // MARK: - Background pipeline

    /// The pixels the fill reaches from the seed, as a mask; nil when there is nothing to
    /// fill. The pixels like the seed's (within the tolerance, inside any selection) are
    /// found first, then the region of them joined to the seed (`FillMask`), with a gap in
    /// the lines closed and the region spread if asked.
    private static func performFill(
        staging: MTLTexture,
        startX sx: Int, startY sy: Int,
        width: Int, height: Int,
        fillColor: StrokeColor,
        tolerance: Int,
        selectionPath: CGPath?,
        readsOwnLayer: Bool,
        closingGaps: Int,
        spread: Int
    ) -> Result? {
        let pixelCount = width * height
        let bytesPerRow = width * 8
        let signpostRead = OSSignpostID(log: log)

        // 1. Copy F16 bytes from the shared texture into a Swift buffer (memcpy speed).
        os_signpost(.begin, log: log, name: "getBytes", signpostID: signpostRead)
        var pixels = [UInt16](repeating: 0, count: pixelCount * 4)
        pixels.withUnsafeMutableBytes { raw in
            staging.getBytes(
                raw.baseAddress!,
                bytesPerRow: bytesPerRow,
                from: MTLRegion(
                    origin: MTLOrigin(x: 0, y: 0, z: 0),
                    size: MTLSize(width: width, height: height, depth: 1)
                ),
                mipmapLevel: 0
            )
        }
        os_signpost(.end, log: log, name: "getBytes", signpostID: signpostRead)

        // 2. The seed's colour, and the fill's
        let targetIdx = (sy * width + sx) * 4
        let targetR = Float(Float16(bitPattern: pixels[targetIdx + 0]))
        let targetG = Float(Float16(bitPattern: pixels[targetIdx + 1]))
        let targetB = Float(Float16(bitPattern: pixels[targetIdx + 2]))
        let targetA = Float(Float16(bitPattern: pixels[targetIdx + 3]))
        let newR = Float16(fillColor.red).bitPattern
        let newG = Float16(fillColor.green).bitPattern
        let newB = Float16(fillColor.blue).bitPattern
        let newA = Float16(fillColor.alpha).bitPattern

        // Filling a layer's own colour with itself does nothing
        if readsOwnLayer, pixels[targetIdx + 0] == newR, pixels[targetIdx + 1] == newG,
           pixels[targetIdx + 2] == newB, pixels[targetIdx + 3] == newA {
            return nil
        }

        // Tolerance scaled from 0-100 int to normalized color distance squared.
        // 100 maps to ≈ 0.4 normalized (~RGB distance of 100/255 per channel).
        let tolNorm = Float(tolerance) / 255.0
        let tolSq = (tolNorm * tolNorm) * 4

        // 3. Optional selection mask (1 byte per pixel, Y-down to match texture layout).
        var selMask: [UInt8]? = nil
        if let path = selectionPath {
            selMask = rasterizeMask(path: path, width: width, height: height)
            if selMask![sy * width + sx] == 0 { return nil }
        }

        // 4. The pixels like the seed's
        let signpostFill = OSSignpostID(log: log)
        os_signpost(.begin, log: log, name: "scanlineFill", signpostID: signpostFill)
        var open = [UInt8](repeating: 0, count: pixelCount)
        pixels.withUnsafeBufferPointer { p in
            open.withUnsafeMutableBufferPointer { o in
                let selection = selMask
                for i in 0..<pixelCount {
                    if let selection, selection[i] == 0 { continue }
                    let c = i * 4
                    // On its own layer, paint already the fill's colour is not filled again
                    if readsOwnLayer, p[c] == newR, p[c + 1] == newG, p[c + 2] == newB, p[c + 3] == newA { continue }
                    let dr = Float(Float16(bitPattern: p[c])) - targetR
                    let dg = Float(Float16(bitPattern: p[c + 1])) - targetG
                    let db = Float(Float16(bitPattern: p[c + 2])) - targetB
                    let da = Float(Float16(bitPattern: p[c + 3])) - targetA
                    if dr * dr + dg * dg + db * db + da * da <= tolSq { o[i] = 1 }
                }
            }
        }

        // 5. The region joined to the seed, a gap closed; spread under the lines
        guard var region = FillMask.region(open: open, width: width, height: height, seed: (sx, sy),
                                           closingGaps: closingGaps) else {
            os_signpost(.end, log: log, name: "scanlineFill", signpostID: signpostFill)
            return nil
        }
        if spread > 0 {
            region = FillMask.dilate(region, width: width, height: height, radius: spread)
            if let selMask { for i in 0..<pixelCount where selMask[i] == 0 { region[i] = 0 } }
        }
        os_signpost(.end, log: log, name: "scanlineFill", signpostID: signpostFill)

        // 6. The mask of what was reached, cropped to its box.
        var minX = width, maxX = -1, minY = height, maxY = -1
        for y in 0..<height {
            let row = y * width
            for x in 0..<width where region[row + x] != 0 {
                if x < minX { minX = x }
                if x > maxX { maxX = x }
                if y < minY { minY = y }
                maxY = y
            }
        }
        guard maxX >= minX, maxY >= minY else { return nil }
        let boxW = maxX - minX + 1, boxH = maxY - minY + 1
        var mask = [UInt8](repeating: 0, count: boxW * boxH)
        for y in 0..<boxH {
            let row = (minY + y) * width + minX
            for x in 0..<boxW where region[row + x] != 0 { mask[y * boxW + x] = 255 }
        }
        return Result(origin: (minX, minY), width: boxW, height: boxH, mask: mask)
    }

    /// Rasterize a CGPath (canvas coords, Y-up) into an 8-bit mask buffer.
    /// 1 = inside selection, 0 = outside. Matches Metal texture Y-down layout.
    private static func rasterizeMask(path: CGPath, width: Int, height: Int) -> [UInt8] {
        var mask = [UInt8](repeating: 0, count: width * height)
        guard let colorSpace = CGColorSpace(name: CGColorSpace.linearGray) else { return mask }

        mask.withUnsafeMutableBytes { raw in
            guard let ctx = CGContext(
                data: raw.baseAddress, width: width, height: height,
                bitsPerComponent: 8, bytesPerRow: width,
                space: colorSpace,
                bitmapInfo: CGImageAlphaInfo.none.rawValue
            ) else { return }
            ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
            ctx.addPath(path)
            ctx.fillPath()
        }
        return mask
    }
}
