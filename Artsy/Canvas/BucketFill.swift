import Foundation
import Metal
import CoreGraphics
import AppKit
import os.log

/// CPU scanline flood fill for a layer's rgba16Float texture.
///
/// Operates directly on the native F16 texture bytes — no intermediate U8 conversion
/// — and reuses a single shared staging texture for both the read and write blits.
/// Main thread stays fully responsive; all heavy work runs on a background queue
/// triggered by the GPU's `addCompletedHandler`.
enum BucketFill {

    private static let log = OSLog(subsystem: "com.artsy.app", category: "BucketFill")

    static func fillAsync(
        renderer: CanvasRenderer,
        layer: Layer,
        canvasPoint: CGPoint,
        canvasSize: CGSize,
        fillColor: StrokeColor,
        tolerance: Int,
        selectionPath: CGPath?,
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
                performFill(
                    staging: staging,
                    targetTexture: targetTexture,
                    startX: sx, startY: sy,
                    width: width, height: height,
                    canvasSize: canvasSize,
                    fillColor: fillColor,
                    tolerance: tolerance,
                    selectionPath: selectionPath,
                    context: context
                )
                DispatchQueue.main.async(execute: onComplete)
            }
        }
        cmdBuf.commit()
    }

    // MARK: - Background pipeline

    private static func performFill(
        staging: MTLTexture,
        targetTexture: MTLTexture,
        startX sx: Int, startY sy: Int,
        width: Int, height: Int,
        canvasSize: CGSize,
        fillColor: StrokeColor,
        tolerance: Int,
        selectionPath: CGPath?,
        context: MetalContext
    ) {
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
            return
        }

        // Tolerance scaled from 0-100 int to normalized color distance squared.
        // 100 maps to ≈ 0.4 normalized (~RGB distance of 100/255 per channel).
        let tolNorm = Float(tolerance) / 255.0
        let tolSq = (tolNorm * tolNorm) * 4

        // 3. Optional selection mask (1 byte per pixel, Y-down to match texture layout).
        var selMask: [UInt8]? = nil
        if let path = selectionPath {
            selMask = rasterizeMask(path: path, width: width, height: height)
            if selMask![sy * width + sx] == 0 { return }
        }

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

        // 5. Upload modified pixels back into staging, blit to target.
        let signpostWrite = OSSignpostID(log: log)
        os_signpost(.begin, log: log, name: "uploadAndBlit", signpostID: signpostWrite)

        pixels.withUnsafeBytes { raw in
            staging.replace(
                region: MTLRegion(
                    origin: MTLOrigin(x: 0, y: 0, z: 0),
                    size: MTLSize(width: width, height: height, depth: 1)
                ),
                mipmapLevel: 0,
                withBytes: raw.baseAddress!,
                bytesPerRow: bytesPerRow
            )
        }

        if let cmdBuf = context.commandQueue.makeCommandBuffer(),
           let blit = cmdBuf.makeBlitCommandEncoder() {
            blit.copy(from: staging, to: targetTexture)
            blit.endEncoding()
            cmdBuf.commit()
            cmdBuf.waitUntilCompleted()
        }

        os_signpost(.end, log: log, name: "uploadAndBlit", signpostID: signpostWrite)
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
