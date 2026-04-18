import Foundation
import Metal
import AppKit

/// Manages the "cut and move" operation when dragging a selection.
/// Uses a Metal compute shader for fast GPU-side masked cut — no CPU readback.
final class SelectionMoveHandler {
    var floatingTexture: MTLTexture?
    var floatingOffset: CGPoint = .zero
    var isActive: Bool { floatingTexture != nil }

    /// Begin a selection move: cut the pixels inside `selectionPath` from the layer
    /// into a floating texture using a GPU compute shader.
    func begin(
        selectionPath: CGPath,
        layer: Layer,
        context: MetalContext,
        textureManager: TextureManager
    ) {
        let w = layer.texture.width
        let h = layer.texture.height
        floatingOffset = .zero

        // 1. Rasterize selection path into a mask texture on CPU (fast — just CoreGraphics fill)
        guard let maskTexture = createMaskTexture(path: selectionPath, width: w, height: h, context: context) else { return }

        // 2. Create floating texture
        guard let floating = try? textureManager.makeCanvasTexture(width: w, height: h, label: "Floating") else { return }

        // 3. Run GPU compute shader to cut masked pixels
        guard let commandBuffer = context.commandQueue.makeCommandBuffer(),
              let encoder = commandBuffer.makeComputeCommandEncoder() else { return }

        encoder.setComputePipelineState(context.maskedCutPipelineState)
        encoder.setTexture(layer.texture, index: 0)   // source (read-write)
        encoder.setTexture(floating, index: 1)          // floating (write)
        encoder.setTexture(maskTexture, index: 2)       // mask (read)

        let threadGroupSize = MTLSize(width: 16, height: 16, depth: 1)
        let threadGroups = MTLSize(
            width: (w + 15) / 16,
            height: (h + 15) / 16,
            depth: 1
        )
        encoder.dispatchThreadgroups(threadGroups, threadsPerThreadgroup: threadGroupSize)
        encoder.endEncoding()

        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()

        self.floatingTexture = floating
    }

    /// Update the floating offset during drag.
    func updateOffset(dx: CGFloat, dy: CGFloat) {
        floatingOffset.x += dx
        floatingOffset.y += dy
    }

    /// Finalize: stamp the floating content back onto the layer at the current offset.
    func commit(
        layer: Layer,
        context: MetalContext,
        textureManager: TextureManager,
        compositor: CompositorPipeline
    ) {
        guard let floating = floatingTexture else { return }
        let w = layer.texture.width
        let h = layer.texture.height
        let dx = Int(floatingOffset.x)
        let dy = Int(-floatingOffset.y) // flip Y

        if dx == 0 && dy == 0 {
            guard let cb = context.commandQueue.makeCommandBuffer() else { return }
            compositor.compositeNormal(source: floating, onto: layer.texture, opacity: 1.0, commandBuffer: cb)
            cb.commit()
            cb.waitUntilCompleted()
        } else {
            // Blit floating to shifted position
            guard let shifted = try? textureManager.makeCanvasTexture(width: w, height: h, label: "Shifted"),
                  let cb = context.commandQueue.makeCommandBuffer() else { return }
            textureManager.clearTexture(shifted, commandBuffer: cb)
            cb.commit()
            cb.waitUntilCompleted()

            let srcX = max(0, -dx)
            let srcY = max(0, -dy)
            let dstX = max(0, dx)
            let dstY = max(0, dy)
            let copyW = w - abs(dx)
            let copyH = h - abs(dy)

            if copyW > 0, copyH > 0 {
                guard let cb2 = context.commandQueue.makeCommandBuffer(),
                      let blit = cb2.makeBlitCommandEncoder() else { return }
                blit.copy(from: floating,
                          sourceSlice: 0, sourceLevel: 0,
                          sourceOrigin: MTLOrigin(x: srcX, y: srcY, z: 0),
                          sourceSize: MTLSize(width: copyW, height: copyH, depth: 1),
                          to: shifted,
                          destinationSlice: 0, destinationLevel: 0,
                          destinationOrigin: MTLOrigin(x: dstX, y: dstY, z: 0))
                blit.endEncoding()
                cb2.commit()
                cb2.waitUntilCompleted()
            }

            guard let cb3 = context.commandQueue.makeCommandBuffer() else { return }
            compositor.compositeNormal(source: shifted, onto: layer.texture, opacity: 1.0, commandBuffer: cb3)
            cb3.commit()
            cb3.waitUntilCompleted()
        }

        floatingTexture = nil
        floatingOffset = .zero
    }

    func cancel() {
        floatingTexture = nil
        floatingOffset = .zero
    }

    // MARK: - Mask Texture Creation

    /// Rasterize a CGPath to a GPU texture for the compute shader mask.
    private func createMaskTexture(path: CGPath, width: Int, height: Int, context: MetalContext) -> MTLTexture? {
        // Rasterize path into CPU bitmap
        guard let cgContext = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }

        cgContext.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        cgContext.addPath(path)
        cgContext.fillPath()

        guard let data = cgContext.data else { return nil }

        // Create a shared texture and upload
        let desc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba8Unorm,
            width: width,
            height: height,
            mipmapped: false
        )
        desc.usage = [.shaderRead]
        #if arch(arm64)
        desc.storageMode = .shared
        #else
        desc.storageMode = .managed
        #endif

        guard let texture = context.device.makeTexture(descriptor: desc) else { return nil }

        texture.replace(
            region: MTLRegion(origin: .init(x: 0, y: 0, z: 0),
                              size: .init(width: width, height: height, depth: 1)),
            mipmapLevel: 0,
            withBytes: data,
            bytesPerRow: width * 4
        )

        return texture
    }
}
