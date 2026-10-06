import Foundation
import Metal
import CoreGraphics

/// Live session for the Transform tool. Holds a GPU snapshot of the content
/// being transformed — either the whole active layer, or the pixels inside
/// the active selection when one exists — and a mutable affine transform
/// that the UI adjusts via handles.
///
/// The renderer reads `sourceTexture` + `currentTransform` to composite a
/// real-time preview onto the main composite texture. When a selection was
/// used, the layer retains everything OUTSIDE the selection and the session
/// renders the transformed inside-selection pixels on top.
final class TransformSession {

    /// GPU snapshot of the source content — sampled during preview, stamped
    /// back onto the layer when the transform is committed.
    let sourceTexture: MTLTexture
    /// The thickness of that content, when the layer has a height map; transformed with it.
    let sourceHeight: MTLTexture?

    /// The target layer whose content was extracted into `sourceTexture`.
    let targetLayer: Layer

    /// Canvas coords. Used for coordinate conversion only — sourceBounds
    /// is what the transform geometry operates on.
    let canvasSize: CGSize

    /// Canvas-space bounding box of the content inside `sourceTexture`.
    /// For a whole-layer transform this is `(0, 0, W, H)`. For a selection
    /// transform it's the selection path's bounding box (clipped to canvas).
    let sourceBounds: CGRect

    /// True if the session was started with an active selection path.
    let hasSelection: Bool

    /// User-adjusted transform (identity = no change from original placement).
    var currentTransform: CGAffineTransform = .identity

    private var historyStack: [CGAffineTransform] = []
    private var redoStack: [CGAffineTransform] = []

    init(
        sourceTexture: MTLTexture,
        sourceHeight: MTLTexture? = nil,
        targetLayer: Layer,
        canvasSize: CGSize,
        sourceBounds: CGRect,
        hasSelection: Bool
    ) {
        self.sourceTexture = sourceTexture
        self.sourceHeight = sourceHeight
        self.targetLayer = targetLayer
        self.canvasSize = canvasSize
        self.sourceBounds = sourceBounds
        self.hasSelection = hasSelection
    }

    // MARK: - Begin / commit / cancel

    /// Begin a transform session.
    ///
    /// If `selectionPath` is provided:
    ///   - masked pixels inside the path are cut out of `targetLayer.texture`
    ///     into a floating source texture
    ///   - the layer retains everything outside the selection
    ///   - `sourceBounds` = path's bounding box (clipped to canvas)
    ///
    /// Otherwise:
    ///   - the entire layer is copied into the source texture and the layer
    ///     is cleared
    ///   - `sourceBounds` = the whole canvas
    static func begin(
        targetLayer: Layer,
        canvasSize: CGSize,
        selectionPath: CGPath?,
        context: MetalContext,
        textureManager: TextureManager
    ) -> TransformSession? {
        let W = targetLayer.texture.width
        let H = targetLayer.texture.height

        guard let source = try? textureManager.makeCanvasTexture(
            width: W, height: H, label: "TransformSource"
        ),
        let cmdBuf = context.commandQueue.makeCommandBuffer() else { return nil }

        // Clear the floating source to transparent.
        textureManager.clearTexture(source, commandBuffer: cmdBuf)

        // The paint's thickness goes along with it
        var sourceHeight: MTLTexture?
        if targetLayer.heightTexture != nil,
           let height = try? textureManager.makeHeightTexture(width: W, height: H, label: "TransformSourceHeight") {
            textureManager.clearTexture(height, commandBuffer: cmdBuf)
            sourceHeight = height
        }
        var cuts: [(from: MTLTexture, to: MTLTexture)] = [(targetLayer.texture, source)]
        if let layerHeight = targetLayer.heightTexture, let sourceHeight { cuts.append((layerHeight, sourceHeight)) }

        let bounds: CGRect
        let hasSelection: Bool

        if let path = selectionPath {
            // Rasterize the selection path into a mask, then use the masked-cut
            // compute shader to move inside-mask pixels from layer → source.
            guard let mask = Self.makeMaskTexture(
                path: path, width: W, height: H, context: context
            ) else { return nil }

            guard let encoder = cmdBuf.makeComputeCommandEncoder() else { return nil }
            encoder.setComputePipelineState(context.maskedCutPipelineState)
            let tg = MTLSize(width: 16, height: 16, depth: 1)
            let groups = MTLSize(width: (W + 15) / 16, height: (H + 15) / 16, depth: 1)
            for cut in cuts {
                encoder.setTexture(cut.from, index: 0)
                encoder.setTexture(cut.to, index: 1)
                encoder.setTexture(mask, index: 2)
                encoder.dispatchThreadgroups(groups, threadsPerThreadgroup: tg)
            }
            encoder.endEncoding()

            let boxCanvas = path.boundingBoxOfPath.intersection(
                CGRect(x: 0, y: 0, width: canvasSize.width, height: canvasSize.height)
            )
            bounds = boxCanvas.isEmpty ? CGRect(x: 0, y: 0, width: canvasSize.width, height: canvasSize.height) : boxCanvas
            hasSelection = true
        } else {
            // Whole layer: blit the layer into the source, then clear the layer.
            guard let blit = cmdBuf.makeBlitCommandEncoder() else { return nil }
            for cut in cuts { blit.copy(from: cut.from, to: cut.to) }
            blit.endEncoding()
            for cut in cuts { textureManager.clearTexture(cut.from, commandBuffer: cmdBuf) }
            bounds = CGRect(x: 0, y: 0, width: canvasSize.width, height: canvasSize.height)
            hasSelection = false
        }

        cmdBuf.commit()
        cmdBuf.waitUntilCompleted()

        return TransformSession(
            sourceTexture: source,
            sourceHeight: sourceHeight,
            targetLayer: targetLayer,
            canvasSize: canvasSize,
            sourceBounds: bounds,
            hasSelection: hasSelection
        )
    }

    /// Commit: stamp the transformed source back onto the target layer.
    /// For whole-layer sessions the layer is already cleared, so the stamp
    /// lands on an empty layer. For selection sessions, the layer still
    /// holds the outside-selection pixels — stamping composites on top.
    func commit(
        context: MetalContext,
        textureManager: TextureManager,
        compositor: CompositorPipeline
    ) {
        guard let cmdBuf = context.commandQueue.makeCommandBuffer() else { return }
        stamp(with: currentTransform, compositor: compositor, commandBuffer: cmdBuf)
        cmdBuf.commit()
        // No wait — next render frame picks up the new content.
    }

    /// The source, and its thickness, onto the layer through `transform`.
    private func stamp(with transform: CGAffineTransform, compositor: CompositorPipeline, commandBuffer: MTLCommandBuffer) {
        var stamps: [(from: MTLTexture, onto: MTLTexture)] = [(sourceTexture, targetLayer.texture)]
        if let sourceHeight, let height = targetLayer.heightTexture { stamps.append((sourceHeight, height)) }
        for stamp in stamps {
            compositor.compositeWithAffineTransform(
                source: stamp.from,
                sourceRect: sourceBounds,
                onto: stamp.onto,
                canvasSize: canvasSize,
                transform: transform,
                opacity: 1.0,
                commandBuffer: commandBuffer
            )
        }
    }

    /// Cancel: restore the original state by stamping the source back at
    /// identity. Works identically for whole-layer and selection sessions.
    func cancel(
        context: MetalContext,
        textureManager: TextureManager,
        compositor: CompositorPipeline
    ) {
        guard let cmdBuf = context.commandQueue.makeCommandBuffer() else { return }
        stamp(with: .identity, compositor: compositor, commandBuffer: cmdBuf)
        cmdBuf.commit()
    }

    // MARK: - Intra-session undo

    func pushHistoryState(_ state: CGAffineTransform) {
        historyStack.append(state)
        redoStack.removeAll()
    }

    @discardableResult
    func undoLastDrag() -> Bool {
        guard let prev = historyStack.popLast() else { return false }
        redoStack.append(currentTransform)
        currentTransform = prev
        return true
    }

    @discardableResult
    func redoLastDrag() -> Bool {
        guard let next = redoStack.popLast() else { return false }
        historyStack.append(currentTransform)
        currentTransform = next
        return true
    }

    var hasUndoableHistory: Bool { !historyStack.isEmpty }
    var hasRedoableHistory: Bool { !redoStack.isEmpty }

    // MARK: - Geometry helpers (use sourceBounds, not canvas)

    var transformedBounds: CGRect {
        sourceBounds.applying(currentTransform)
    }

    /// Four corners of the transformed source bbox in canvas coords,
    /// in order: TL (Y-up top-left), TR, BR, BL.
    var transformedCorners: [CGPoint] {
        let minX = sourceBounds.minX, maxX = sourceBounds.maxX
        let minY = sourceBounds.minY, maxY = sourceBounds.maxY
        return [
            CGPoint(x: minX, y: maxY).applying(currentTransform), // TL
            CGPoint(x: maxX, y: maxY).applying(currentTransform), // TR
            CGPoint(x: maxX, y: minY).applying(currentTransform), // BR
            CGPoint(x: minX, y: minY).applying(currentTransform), // BL
        ]
    }

    /// Center of the transformed source bbox.
    var transformedCenter: CGPoint {
        CGPoint(x: sourceBounds.midX, y: sourceBounds.midY).applying(currentTransform)
    }

    // MARK: - Mask rasterization

    /// Rasterize a CGPath (canvas coords, Y-up) into a GPU texture suitable
    /// for `maskedCutKernel`. Same convention used by SelectionMoveHandler.
    private static func makeMaskTexture(
        path: CGPath, width: Int, height: Int, context: MetalContext
    ) -> MTLTexture? {
        guard let cgCtx = CGContext(
            data: nil,
            width: width, height: height,
            bitsPerComponent: 8, bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        cgCtx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        cgCtx.addPath(path)
        cgCtx.fillPath()
        guard let data = cgCtx.data else { return nil }

        let desc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba8Unorm, width: width, height: height, mipmapped: false
        )
        desc.usage = [.shaderRead]
        #if arch(arm64)
        desc.storageMode = .shared
        #else
        desc.storageMode = .managed
        #endif

        guard let texture = context.device.makeTexture(descriptor: desc) else { return nil }
        texture.replace(
            region: MTLRegion(
                origin: MTLOrigin(x: 0, y: 0, z: 0),
                size: MTLSize(width: width, height: height, depth: 1)
            ),
            mipmapLevel: 0,
            withBytes: data,
            bytesPerRow: width * 4
        )
        return texture
    }
}

/// Identifies which transform handle the user is currently dragging.
enum TransformHandle: Equatable {
    case translate
    case scaleTL
    case scaleTR
    case scaleBR
    case scaleBL
    case rotate
    case none

    var isScale: Bool {
        switch self {
        case .scaleTL, .scaleTR, .scaleBR, .scaleBL: return true
        default: return false
        }
    }
}
