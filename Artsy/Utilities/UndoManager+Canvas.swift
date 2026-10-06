import Foundation
import Metal
import CoreGraphics

/// Snapshot-based undo/redo.
///
/// Most actions save a complete snapshot of all layers, their textures, properties, and the
/// active layer index, which handles every case: adding/removing layers, reordering,
/// property changes, fills, pastes. A brush or eraser stroke only changes pixels inside its
/// own bounds on one layer, so it saves just that rectangle.
final class CanvasUndoManager {
    private enum Entry {
        case stack(StackSnapshot)
        case region(RegionSnapshot)
    }

    private var undoStack: [Entry] = []
    private var redoStack: [Entry] = []

    /// Most steps kept, however little memory they take.
    let maxUndoLevels: Int = 200
    /// Whole-stack snapshots are large, so memory is the real limit: history may use what
    /// this many of them would. Strokes store a small rectangle each and so go much deeper.
    let wholeStackSnapshotsInBudget = 25
    /// Size of one whole-stack snapshot of the canvas, as last seen.
    private var stackBytes = 0

    struct LayerSnapshot {
        let id: UUID
        let name: String
        let isVisible: Bool
        let isLocked: Bool
        let opacity: Float
        let blendMode: LayerBlendMode
        let texture: MTLTexture  // GPU copy
    }

    struct StackSnapshot {
        let layers: [LayerSnapshot]
        let activeLayerIndex: Int
        let selectionPath: CGPath?
        let description: String
    }

    /// The pixels of one rectangle of one layer.
    struct RegionSnapshot {
        let layerID: UUID
        /// Position in the layer texture (pixels, origin top-left)
        let region: MTLScissorRect
        /// GPU copy, the size of `region`
        let texture: MTLTexture
        let description: String
    }

    var canUndo: Bool { !undoStack.isEmpty }
    var canRedo: Bool { !redoStack.isEmpty }

    /// Save the full layer stack state BEFORE performing an action.
    func saveSnapshot(layerStack: LayerStack, selectionPath: CGPath?, context: MetalContext, description: String) {
        guard let snapshot = captureStack(layerStack: layerStack, selectionPath: selectionPath, context: context, description: description) else { return }
        noteStackSize(layerStack)
        push(.stack(snapshot))
    }

    /// Save one rectangle of a layer BEFORE a stroke is merged into it.
    /// The copy is encoded into `commandBuffer`, so it runs ahead of whatever that buffer
    /// does to the layer next.
    func saveRegion(of layer: Layer, in layerStack: LayerStack, region: MTLScissorRect, context: MetalContext,
                    description: String, commandBuffer: MTLCommandBuffer) {
        guard let snapshot = captureRegion(of: layer, region: region, context: context,
                                           description: description, commandBuffer: commandBuffer) else { return }
        noteStackSize(layerStack)
        push(.region(snapshot))
    }

    private func noteStackSize(_ layerStack: LayerStack) {
        stackBytes = layerStack.layers.reduce(0) { $0 + $1.texture.width * $1.texture.height * 8 }
    }

    private func push(_ entry: Entry) {
        undoStack.append(entry)
        redoStack.removeAll()

        // Drop the oldest steps once there are too many or they hold too much memory.
        let budget = stackBytes * wholeStackSnapshotsInBudget
        var used = undoStack.reduce(0) { $0 + Self.bytes(of: $1) }
        while undoStack.count > 1, undoStack.count > maxUndoLevels || used > budget {
            used -= Self.bytes(of: undoStack.removeFirst())
        }
    }

    /// Number of steps that can be undone.
    var undoCount: Int { undoStack.count }

    /// Undo: restore the previous snapshot.
    func undo(layerStack: LayerStack, viewModel: CanvasViewModel, context: MetalContext) {
        guard let entry = undoStack.popLast() else { return }
        if let inverse = apply(entry, layerStack: layerStack, viewModel: viewModel, context: context) {
            redoStack.append(inverse)
        }
    }

    /// Redo: restore the state that was undone.
    func redo(layerStack: LayerStack, viewModel: CanvasViewModel, context: MetalContext) {
        guard let entry = redoStack.popLast() else { return }
        if let inverse = apply(entry, layerStack: layerStack, viewModel: viewModel, context: context) {
            undoStack.append(inverse)
        }
    }

    /// Restore `entry` and return an entry that reverses the restore.
    private func apply(_ entry: Entry, layerStack: LayerStack, viewModel: CanvasViewModel, context: MetalContext) -> Entry? {
        switch entry {
        case .stack(let snapshot):
            let current = captureStack(layerStack: layerStack, selectionPath: viewModel.selectionPath, context: context, description: snapshot.description)
            restoreStack(snapshot: snapshot, layerStack: layerStack, context: context)
            viewModel.selectionPath = snapshot.selectionPath
            return current.map(Entry.stack)

        case .region(let snapshot):
            guard let layer = layerStack.layers.first(where: { $0.id == snapshot.layerID }),
                  let commandBuffer = context.commandQueue.makeCommandBuffer() else { return nil }
            let current = captureRegion(of: layer, region: snapshot.region, context: context,
                                        description: snapshot.description, commandBuffer: commandBuffer)
            if let blit = commandBuffer.makeBlitCommandEncoder() {
                blit.copy(from: snapshot.texture,
                          sourceSlice: 0, sourceLevel: 0,
                          sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0),
                          sourceSize: MTLSize(width: snapshot.region.width, height: snapshot.region.height, depth: 1),
                          to: layer.texture,
                          destinationSlice: 0, destinationLevel: 0,
                          destinationOrigin: MTLOrigin(x: snapshot.region.x, y: snapshot.region.y, z: 0))
                blit.endEncoding()
            }
            commandBuffer.commit()
            return current.map(Entry.region)
        }
    }

    func clear() {
        undoStack.removeAll()
        redoStack.removeAll()
    }

    /// Discard the most recent undo entry without restoring it. Used by tools that
    /// save a snapshot speculatively (e.g. Transform) but then cancel with no net change.
    func popLastSnapshot() {
        _ = undoStack.popLast()
    }

    /// Bytes of texture memory held by the undo and redo stacks.
    var textureBytes: Int {
        (undoStack + redoStack).reduce(0) { $0 + Self.bytes(of: $1) }
    }

    private static func bytes(of entry: Entry) -> Int {
        switch entry {
        case .stack(let snapshot):
            return snapshot.layers.reduce(0) { $0 + $1.texture.width * $1.texture.height * 8 }
        case .region(let snapshot):
            return snapshot.texture.width * snapshot.texture.height * 8
        }
    }

    // MARK: - Snapshot Capture & Restore

    private func captureRegion(of layer: Layer, region: MTLScissorRect, context: MetalContext,
                               description: String, commandBuffer: MTLCommandBuffer) -> RegionSnapshot? {
        guard region.width > 0, region.height > 0 else { return nil }
        let desc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: layer.texture.pixelFormat,
            width: region.width,
            height: region.height,
            mipmapped: false
        )
        desc.usage = [.shaderRead]
        desc.storageMode = .private

        guard let copy = context.device.makeTexture(descriptor: desc),
              let blit = commandBuffer.makeBlitCommandEncoder() else { return nil }
        blit.copy(from: layer.texture,
                  sourceSlice: 0, sourceLevel: 0,
                  sourceOrigin: MTLOrigin(x: region.x, y: region.y, z: 0),
                  sourceSize: MTLSize(width: region.width, height: region.height, depth: 1),
                  to: copy,
                  destinationSlice: 0, destinationLevel: 0,
                  destinationOrigin: MTLOrigin(x: 0, y: 0, z: 0))
        blit.endEncoding()
        return RegionSnapshot(layerID: layer.id, region: region, texture: copy, description: description)
    }

    private func captureStack(layerStack: LayerStack, selectionPath: CGPath?, context: MetalContext, description: String) -> StackSnapshot? {
        var layerSnapshots: [LayerSnapshot] = []

        for layer in layerStack.layers {
            guard let textureCopy = copyTexture(layer.texture, context: context) else { return nil }
            layerSnapshots.append(LayerSnapshot(
                id: layer.id,
                name: layer.name,
                isVisible: layer.isVisible,
                isLocked: layer.isLocked,
                opacity: layer.opacity,
                blendMode: layer.blendMode,
                texture: textureCopy
            ))
        }

        return StackSnapshot(
            layers: layerSnapshots,
            activeLayerIndex: layerStack.activeLayerIndex,
            selectionPath: selectionPath?.copy(),
            description: description
        )
    }

    private func restoreStack(snapshot: StackSnapshot, layerStack: LayerStack, context: MetalContext) {
        // Match existing layers by ID where possible, create new ones where needed
        var newLayers: [Layer] = []

        for snap in snapshot.layers {
            // Try to reuse existing layer object
            if let existing = layerStack.layers.first(where: { $0.id == snap.id }) {
                existing.name = snap.name
                existing.isVisible = snap.isVisible
                existing.isLocked = snap.isLocked
                existing.opacity = snap.opacity
                existing.blendMode = snap.blendMode
                // Restore texture
                blitCopy(from: snap.texture, to: existing.texture, context: context)
                newLayers.append(existing)
            } else {
                // Layer was deleted — recreate it
                let desc = MTLTextureDescriptor.texture2DDescriptor(
                    pixelFormat: snap.texture.pixelFormat,
                    width: snap.texture.width,
                    height: snap.texture.height,
                    mipmapped: false
                )
                desc.usage = [.shaderRead, .shaderWrite, .renderTarget]
                desc.storageMode = .private
                guard let newTexture = context.device.makeTexture(descriptor: desc) else { continue }

                let layer = Layer(id: snap.id, name: snap.name, texture: newTexture)
                layer.isVisible = snap.isVisible
                layer.isLocked = snap.isLocked
                layer.opacity = snap.opacity
                layer.blendMode = snap.blendMode
                blitCopy(from: snap.texture, to: newTexture, context: context)
                newLayers.append(layer)
            }
        }

        layerStack.layers = newLayers
        layerStack.activeLayerIndex = min(snapshot.activeLayerIndex, newLayers.count - 1)
    }

    // MARK: - GPU Texture Copy

    /// Capture a GPU texture copy. Does NOT wait for the blit to finish — the
    /// snapshot texture is only read when `undo`/`redo` restores it later,
    /// by which point the GPU has long since drained. Skipping the wait
    /// means `saveUndoSnapshot` doesn't block the main thread.
    private func copyTexture(_ source: MTLTexture, context: MetalContext) -> MTLTexture? {
        let desc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: source.pixelFormat,
            width: source.width,
            height: source.height,
            mipmapped: false
        )
        desc.usage = [.shaderRead, .shaderWrite, .renderTarget]
        desc.storageMode = source.storageMode

        guard let copy = context.device.makeTexture(descriptor: desc),
              let commandBuffer = context.commandQueue.makeCommandBuffer(),
              let blit = commandBuffer.makeBlitCommandEncoder() else {
            return nil
        }

        blit.copy(from: source,
                  sourceSlice: 0, sourceLevel: 0,
                  sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0),
                  sourceSize: MTLSize(width: source.width, height: source.height, depth: 1),
                  to: copy,
                  destinationSlice: 0, destinationLevel: 0,
                  destinationOrigin: MTLOrigin(x: 0, y: 0, z: 0))
        blit.endEncoding()
        commandBuffer.commit()
        // No waitUntilCompleted — GPU finishes asynchronously.

        return copy
    }

    /// Restore a snapshot texture's contents into a live layer texture.
    /// Also non-blocking: Metal serializes subsequent render passes against
    /// this blit on the same command queue, so the restored content will be
    /// visible by the next frame.
    private func blitCopy(from source: MTLTexture, to destination: MTLTexture, context: MetalContext) {
        guard let commandBuffer = context.commandQueue.makeCommandBuffer(),
              let blit = commandBuffer.makeBlitCommandEncoder() else { return }

        blit.copy(from: source,
                  sourceSlice: 0, sourceLevel: 0,
                  sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0),
                  sourceSize: MTLSize(width: source.width, height: source.height, depth: 1),
                  to: destination,
                  destinationSlice: 0, destinationLevel: 0,
                  destinationOrigin: MTLOrigin(x: 0, y: 0, z: 0))
        blit.endEncoding()
        commandBuffer.commit()
        // No waitUntilCompleted — next render frame picks up the new content.
    }
}
