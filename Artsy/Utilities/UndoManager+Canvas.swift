import Foundation
import Metal
import CoreGraphics

/// Snapshot-based undo/redo that captures the full layer stack state.
/// Every undoable action saves a complete snapshot of all layers, their
/// textures, properties, and the active layer index. This handles all cases:
/// drawing, erasing, adding/removing layers, reordering, property changes.
final class CanvasUndoManager {
    private var undoStack: [StackSnapshot] = []
    private var redoStack: [StackSnapshot] = []
    let maxUndoLevels: Int = 25

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

    var canUndo: Bool { !undoStack.isEmpty }
    var canRedo: Bool { !redoStack.isEmpty }

    /// Save the full layer stack state BEFORE performing an action.
    func saveSnapshot(layerStack: LayerStack, selectionPath: CGPath?, context: MetalContext, description: String) {
        guard let snapshot = captureStack(layerStack: layerStack, selectionPath: selectionPath, context: context, description: description) else { return }
        undoStack.append(snapshot)
        redoStack.removeAll()

        while undoStack.count > maxUndoLevels {
            undoStack.removeFirst()
        }
    }

    /// Undo: restore the previous snapshot.
    func undo(layerStack: LayerStack, viewModel: CanvasViewModel, context: MetalContext) {
        guard let snapshot = undoStack.popLast() else { return }

        if let current = captureStack(layerStack: layerStack, selectionPath: viewModel.selectionPath, context: context, description: snapshot.description) {
            redoStack.append(current)
        }

        restoreStack(snapshot: snapshot, layerStack: layerStack, context: context)
        viewModel.selectionPath = snapshot.selectionPath
    }

    /// Redo: restore the state that was undone.
    func redo(layerStack: LayerStack, viewModel: CanvasViewModel, context: MetalContext) {
        guard let snapshot = redoStack.popLast() else { return }

        if let current = captureStack(layerStack: layerStack, selectionPath: viewModel.selectionPath, context: context, description: snapshot.description) {
            undoStack.append(current)
        }

        restoreStack(snapshot: snapshot, layerStack: layerStack, context: context)
        viewModel.selectionPath = snapshot.selectionPath
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

    // MARK: - Snapshot Capture & Restore

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
