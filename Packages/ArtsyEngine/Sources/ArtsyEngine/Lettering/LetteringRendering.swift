import CoreGraphics
import Foundation
import Metal

extension CanvasRenderer {
    /// Draws `balloons` into `layer` within `rect` (canvas pixels, y up), and only there:
    /// every balloon that touches the rectangle, clipped to it, over nothing, uploaded into
    /// that rectangle of the layer's texture. A lettering layer holds its balloons and
    /// nothing else, so a change redraws only where the balloon was and is; the whole
    /// layer is the same call with the canvas's rectangle.
    public func drawLettering(_ balloons: [Balloon], into layer: Layer, in rect: CGRect) {
        let texture = layer.texture
        let canvas = CGRect(x: 0, y: 0, width: texture.width, height: texture.height)
        let region = rect.integral.intersection(canvas)
        guard !region.isNull, region.width >= 1, region.height >= 1 else { return }
        let width = Int(region.width), height = Int(region.height)
        guard let colorSpace = CGColorSpace(name: CGColorSpace.displayP3),
              let drawing = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                      space: colorSpace, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
              let pixels = drawing.data
        else { return }
        // The context's y runs up, as the canvas's does: only moved to the region's corner
        drawing.translateBy(x: -region.minX, y: -region.minY)
        for balloon in balloons {
            let layout = BalloonLayout(balloon)
            if layout.bounds.intersects(region) { layout.draw(in: drawing) }
        }

        // 8-bit premultiplied, as Core Graphics draws, into the layers' half floats
        let count = width * height * 4
        var halves = [UInt16](repeating: 0, count: count)
        let bytes = pixels.assumingMemoryBound(to: UInt8.self)
        CanvasDocument.u8ToF16LUTPublic.withUnsafeBufferPointer { lut in
            halves.withUnsafeMutableBufferPointer { out in
                for i in 0..<count { out[i] = lut[Int(bytes[i])] }
            }
        }
        guard let staging = try? textureManager.makeSharedTexture(width: width, height: height, label: "Lettering"),
              let commandBuffer = context.commandQueue.makeCommandBuffer(),
              let blit = commandBuffer.makeBlitCommandEncoder() else { return }
        halves.withUnsafeBytes { raw in
            staging.replace(region: MTLRegion(origin: MTLOrigin(x: 0, y: 0, z: 0), size: MTLSize(width: width, height: height, depth: 1)),
                            mipmapLevel: 0, withBytes: raw.baseAddress!, bytesPerRow: width * 8)
        }
        // The texture's first row is the canvas's top
        blit.copy(from: staging, sourceSlice: 0, sourceLevel: 0, sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0),
                  sourceSize: MTLSize(width: width, height: height, depth: 1),
                  to: texture, destinationSlice: 0, destinationLevel: 0,
                  destinationOrigin: MTLOrigin(x: Int(region.minX), y: texture.height - Int(region.maxY), z: 0))
        blit.endEncoding()
        commandBuffer.commit()
        viewModel?.noteContentChanged()
    }

    /// Sets again every balloon set in one of the drawn fonts `ids`, which changed (or went):
    /// each drawn where it is now and, with room for its words having run larger before,
    /// round about. Every balloon a region touches is drawn in it, so the room costs only
    /// time. Not a step to undo: the font changed, not the page.
    public func redrawBalloons(setIn ids: Set<UUID>) {
        guard let viewModel, let layerStack = viewModel.layerStack else { return }
        var changed = false
        for layer in layerStack.layers {
            guard let balloons = layer.lettering else { continue }
            let affected = balloons.filter { $0.drawnFont.map(ids.contains) == true }
            guard !affected.isEmpty else { continue }
            for balloon in affected {
                let bounds = BalloonLayout(balloon).bounds
                let room = max(bounds.width, bounds.height) * 0.5 + balloon.fontSize * 2
                drawLettering(balloons, into: layer, in: bounds.insetBy(dx: -room, dy: -room))
            }
            updateThumbnail(for: layer)
            changed = true
        }
        guard changed else { return }
        viewModel.letteringRevision += 1
        viewModel.markDirty()
    }
}
