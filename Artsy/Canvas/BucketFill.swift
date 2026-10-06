import Foundation
import Metal
import CoreGraphics
import AppKit
import os.log

/// CPU scanline flood fill for a layer's rgba16Float texture.
///
/// Operates directly on the native F16 texture bytes — no intermediate U8 conversion.
/// Main thread stays fully responsive; all heavy work runs on a background queue
/// triggered by the GPU's `addCompletedHandler`. The fill lands through a mask of the
/// pixels it reached, so whatever was painted elsewhere on the layer while it ran stays.
enum BucketFill {

    private static let log = OSLog(subsystem: "com.artsy.app", category: "BucketFill")

    /// What a fill found: the pixels it reached, as a mask the size of their bounding box.
    struct Result {
        let origin: (x: Int, y: Int)
        let width: Int, height: Int
        let mask: [UInt8]
    }

    /// - Parameter shouldApply: asked on the main thread when the fill is ready to land,
    ///   seconds later on a big canvas; false if the undo step it was given has been undone
    ///   meanwhile, or its layer is gone.
    static func fillAsync(
        renderer: CanvasRenderer,
        layer: Layer,
        canvasPoint: CGPoint,
        canvasSize: CGSize,
        fillColor: StrokeColor,
        tolerance: Int,
        selectionPath: CGPath?,
        shouldApply: @escaping () -> Bool = { true },
        onComplete: @escaping () -> Void
    ) {
        let width = layer.texture.width
        let height = layer.texture.height

        // Canvas coords are Y-up; textures are Y-down. Flip.
        let sx = Int(canvasPoint.x.rounded())
        let sy = Int((canvasSize.height - canvasPoint.y).rounded())
        guard sx >= 0, sx < width, sy >= 0, sy < height else {
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
        blit.copy(from: layer.texture, to: staging)
        blit.endEncoding()

        let context = renderer.context
        let targetTexture = layer.texture

        cmdBuf.addCompletedHandler { _ in
            DispatchQueue.global(qos: .userInitiated).async {
                let result = performFill(
                    staging: staging,
                    startX: sx, startY: sy,
                    width: width, height: height,
                    fillColor: fillColor,
                    tolerance: tolerance,
                    selectionPath: selectionPath
                )
                DispatchQueue.main.async {
                    if let result, shouldApply() {
                        apply(result, color: fillColor, to: targetTexture, context: context)
                    }
                    onComplete()
                }
            }
        }
        cmdBuf.commit()
    }

    /// Write the fill's colour where its mask says, and nowhere else.
    static func apply(_ result: Result, color: StrokeColor, to target: MTLTexture, context: MetalContext) {
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
        encoder.setComputePipelineState(context.maskedFillPipelineState)
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

    /// The pixels the fill reaches from the seed, as a mask; nil when there is nothing to fill.
    private static func performFill(
        staging: MTLTexture,
        startX sx: Int, startY sy: Int,
        width: Int, height: Int,
        fillColor: StrokeColor,
        tolerance: Int,
        selectionPath: CGPath?
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

        // 2. Sample target color from the seed pixel (as F16 bits then F32 for compare).
        let targetIdx = (sy * width + sx) * 4
        let targetR = Float(Float16(bitPattern: pixels[targetIdx + 0]))
        let targetG = Float(Float16(bitPattern: pixels[targetIdx + 1]))
        let targetB = Float(Float16(bitPattern: pixels[targetIdx + 2]))
        let targetA = Float(Float16(bitPattern: pixels[targetIdx + 3]))

        // New color as F16 bits (write directly; no scaling).
        let newR = Float16(fillColor.red).bitPattern
        let newG = Float16(fillColor.green).bitPattern
        let newB = Float16(fillColor.blue).bitPattern
        let newA = Float16(fillColor.alpha).bitPattern

        // Already same color at seed → nothing to do.
        if pixels[targetIdx + 0] == newR && pixels[targetIdx + 1] == newG &&
           pixels[targetIdx + 2] == newB && pixels[targetIdx + 3] == newA {
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

        // The pixels reached, and the box around them
        var filled = [UInt8](repeating: 0, count: pixelCount)
        var minX = width, maxX = -1, minY = height, maxY = -1

        // 4. Scanline flood fill, unsafe pointers all the way down.
        let signpostFill = OSSignpostID(log: log)
        os_signpost(.begin, log: log, name: "scanlineFill", signpostID: signpostFill)

        pixels.withUnsafeMutableBufferPointer { pbuf in
            let p = pbuf.baseAddress!
            let maskPtr: UnsafePointer<UInt8>? = selMask?.withUnsafeBufferPointer { $0.baseAddress }
            // NOTE: selMask's underlying memory is owned by the `selMask` array on
            // the caller's stack; we only use maskPtr inside the same synchronous block.

            @inline(__always)
            func matchesF16(_ x: Int, _ y: Int) -> Bool {
                if let m = maskPtr, m[y * width + x] == 0 { return false }
                let i = (y * width + x) * 4
                // Skip if already the new color (prevents re-seeding).
                if p[i] == newR && p[i + 1] == newG && p[i + 2] == newB && p[i + 3] == newA {
                    return false
                }
                let r = Float(Float16(bitPattern: p[i]))
                let g = Float(Float16(bitPattern: p[i + 1]))
                let b = Float(Float16(bitPattern: p[i + 2]))
                let a = Float(Float16(bitPattern: p[i + 3]))
                let dr = r - targetR
                let dg = g - targetG
                let db = b - targetB
                let da = a - targetA
                return (dr*dr + dg*dg + db*db + da*da) <= tolSq
            }

            @inline(__always)
            func setPixelF16(_ x: Int, _ y: Int) {
                let i = (y * width + x) * 4
                p[i] = newR; p[i + 1] = newG; p[i + 2] = newB; p[i + 3] = newA
                filled[y * width + x] = 255
            }

            var stack: [Int32] = [Int32(sx), Int32(sy)]  // flat (x, y) pairs
            stack.reserveCapacity(4096)

            while stack.count >= 2 {
                let seedY = Int(stack.removeLast())
                let seedX = Int(stack.removeLast())
                if !matchesF16(seedX, seedY) { continue }

                var lx = seedX
                while lx > 0 && matchesF16(lx - 1, seedY) { lx -= 1 }
                var rx = seedX
                while rx < width - 1 && matchesF16(rx + 1, seedY) { rx += 1 }

                // Fill span
                for xi in lx...rx { setPixelF16(xi, seedY) }
                minX = min(minX, lx); maxX = max(maxX, rx)
                minY = min(minY, seedY); maxY = max(maxY, seedY)

                // Scan neighbor rows for new seeds
                if seedY > 0 {
                    var inRun = false
                    for xi in lx...rx {
                        if matchesF16(xi, seedY - 1) {
                            if !inRun { stack.append(Int32(xi)); stack.append(Int32(seedY - 1)); inRun = true }
                        } else { inRun = false }
                    }
                }
                if seedY < height - 1 {
                    var inRun = false
                    for xi in lx...rx {
                        if matchesF16(xi, seedY + 1) {
                            if !inRun { stack.append(Int32(xi)); stack.append(Int32(seedY + 1)); inRun = true }
                        } else { inRun = false }
                    }
                }
            }
        }

        os_signpost(.end, log: log, name: "scanlineFill", signpostID: signpostFill)
        guard maxX >= minX, maxY >= minY else { return nil }

        // 5. The mask of what was reached, cropped to its box.
        let boxW = maxX - minX + 1, boxH = maxY - minY + 1
        var mask = [UInt8](repeating: 0, count: boxW * boxH)
        for y in 0..<boxH {
            let row = (minY + y) * width + minX
            mask.replaceSubrange(y * boxW ..< (y + 1) * boxW, with: filled[row ..< row + boxW])
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
