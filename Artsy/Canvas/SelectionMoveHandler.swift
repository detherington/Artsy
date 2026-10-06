import Foundation
import Metal
import AppKit

/// Manages the "cut and move" operation when dragging a selection.
/// Uses a Metal compute shader for fast GPU-side masked cut — no CPU readback.
final class SelectionMoveHandler {
    var floatingTexture: MTLTexture?
    /// The thickness of the paint under the selection, if the layer has any; it moves with
    /// the paint.
    var floatingHeight: MTLTexture?
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

        // 2. Create the floating textures
        guard let floating = try? textureManager.makeCanvasTexture(width: w, height: h, label: "Floating"),
              let commandBuffer = context.commandQueue.makeCommandBuffer() else { return }
        var cuts: [(from: MTLTexture, to: MTLTexture)] = [(layer.texture, floating)]
        var floatingHeight: MTLTexture?
        if let height = layer.heightTexture,
           let target = try? textureManager.makeHeightTexture(width: w, height: h, label: "Floating height") {
            textureManager.clearTexture(target, commandBuffer: commandBuffer)
            cuts.append((height, target))
            floatingHeight = target
        }

        // 3. Run GPU compute shader to cut masked pixels
        guard let encoder = commandBuffer.makeComputeCommandEncoder() else { return }
        encoder.setComputePipelineState(context.maskedCutPipelineState)
        let threadGroupSize = MTLSize(width: 16, height: 16, depth: 1)
        let threadGroups = MTLSize(width: (w + 15) / 16, height: (h + 15) / 16, depth: 1)
        for cut in cuts {
            encoder.setTexture(cut.from, index: 0)      // source (read-write)
            encoder.setTexture(cut.to, index: 1)        // floating (write)
            encoder.setTexture(maskTexture, index: 2)   // mask (read)
            encoder.dispatchThreadgroups(threadGroups, threadsPerThreadgroup: threadGroupSize)
        }
        encoder.endEncoding()

        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()

        self.floatingTexture = floating
        self.floatingHeight = floatingHeight
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

        guard let cb = context.commandQueue.makeCommandBuffer() else { return }
        if let shifted = Self.shifted(floating, dx: dx, dy: dy, commandBuffer: cb, textureManager: textureManager, make: {
            try? textureManager.makeCanvasTexture(width: w, height: h, label: "Shifted")
        }) {
            compositor.compositeNormal(source: shifted, onto: layer.texture, opacity: 1.0, commandBuffer: cb)
        }
        // Thickness adds onto whatever thickness the paint lands on
        if let floatingHeight, let height = layer.heightTexture,
           let shifted = Self.shifted(floatingHeight, dx: dx, dy: dy, commandBuffer: cb, textureManager: textureManager, make: {
               try? textureManager.makeHeightTexture(width: w, height: h, label: "Shifted height")
           }) {
            compositor.accumulateHeight(source: shifted, onto: height, opacity: 1.0, commandBuffer: cb)
        }
        cb.commit()
        cb.waitUntilCompleted()

        floatingTexture = nil
        floatingHeight = nil
        floatingOffset = .zero
    }

    /// `texture` moved by (dx, dy): itself when there is no move, otherwise a copy made by
    /// `make`, cleared, with the contents blitted across (pixels moved off the edge are lost).
    private static func shifted(_ texture: MTLTexture, dx: Int, dy: Int, commandBuffer: MTLCommandBuffer,
                                textureManager: TextureManager, make: () -> MTLTexture?) -> MTLTexture? {
        if dx == 0 && dy == 0 { return texture }
        guard let shifted = make() else { return nil }
        textureManager.clearTexture(shifted, commandBuffer: commandBuffer)
        let w = texture.width, h = texture.height
        let copyW = w - abs(dx), copyH = h - abs(dy)
        if copyW > 0, copyH > 0, let blit = commandBuffer.makeBlitCommandEncoder() {
            blit.copy(from: texture,
                      sourceSlice: 0, sourceLevel: 0,
                      sourceOrigin: MTLOrigin(x: max(0, -dx), y: max(0, -dy), z: 0),
                      sourceSize: MTLSize(width: copyW, height: copyH, depth: 1),
                      to: shifted,
                      destinationSlice: 0, destinationLevel: 0,
                      destinationOrigin: MTLOrigin(x: max(0, dx), y: max(0, dy), z: 0))
            blit.endEncoding()
        }
        return shifted
    }

    func cancel() {
        floatingTexture = nil
        floatingHeight = nil
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
