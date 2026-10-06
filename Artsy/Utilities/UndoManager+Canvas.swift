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
    /// But never more than this, whatever the canvas: a big canvas with many layers would
    /// otherwise be allowed tens of gigabytes. The renderer sets it from the GPU's budget.
    var memoryCap = 2 << 30
    /// Size of one whole-stack snapshot of the canvas, as last seen.
    private var stackBytes = 0
    /// Snapshot work still on the GPU; tests wait for it.
    private let pending = DispatchGroup()

    struct LayerSnapshot {
        let id: UUID
        let name: String
        let isVisible: Bool
        let isLocked: Bool
        let opacity: Float
        let blendMode: LayerBlendMode
        /// A GPU copy of the layer's pixels — or, for a layer the action will not change, the
        /// layer's own texture: it is in the right state when this step is undone, since
        /// every later change to it has been undone first.
        let texture: MTLTexture
        /// Likewise the layer's height map, if it had one
        let height: MTLTexture?
        /// Whether `texture` and `height` are copies (and so cost memory) or references.
        let isCopy: Bool
    }

    /// Which layers' pixels an action is about to change, so a snapshot copies only those.
    enum Scope: Equatable {
        /// None: a selection, a layer's order, name or settings, a layer added or deleted.
        case nothing
        /// These layers' pixels.
        case layers([UUID])
        /// Every layer, when the caller cannot say.
        case everything

        static func layer(_ layer: Layer?) -> Scope { layer.map { .layers([$0.id]) } ?? .everything }

        func includes(_ id: UUID) -> Bool {
            switch self {
            case .nothing: return false
            case .layers(let ids): return ids.contains(id)
            case .everything: return true
            }
        }
    }

    /// A class, so that layers found unchanged since the previous snapshot can be pointed
    /// at its copies once the GPU has compared them — from the GPU's completion thread,
    /// hence the lock.
    final class StackSnapshot {
        private var storage: [LayerSnapshot]
        private let lock = NSLock()
        let activeLayerIndex: Int
        let selectionPath: CGPath?
        let description: String

        init(layers: [LayerSnapshot], activeLayerIndex: Int, selectionPath: CGPath?, description: String) {
            self.storage = layers
            self.activeLayerIndex = activeLayerIndex
            self.selectionPath = selectionPath
            self.description = description
        }

        var layers: [LayerSnapshot] {
            lock.lock(); defer { lock.unlock() }
            return storage
        }

        func replaceLayer(at index: Int, with layer: LayerSnapshot) {
            lock.lock(); defer { lock.unlock() }
            storage[index] = layer
        }
    }

    /// The pixels of one rectangle of one layer.
    struct RegionSnapshot {
        let layerID: UUID
        /// Position in the layer texture (pixels, origin top-left)
        let region: MTLScissorRect
        /// GPU copy, the size of `region`
        let texture: MTLTexture
        /// The same rectangle of the layer's height map, if it had one
        let height: MTLTexture?
        let description: String
    }

    var canUndo: Bool { !undoStack.isEmpty }
    var canRedo: Bool { !redoStack.isEmpty }

    /// Save the layer stack's state BEFORE performing an action: every layer's settings and
    /// order, the selection, and the pixels of the layers in `scope`. With `.everything`,
    /// layers that have not changed since the last whole-stack snapshot end up sharing its
    /// copies once the GPU has compared them.
    func saveSnapshot(layerStack: LayerStack, selectionPath: CGPath?, scope: Scope = .everything,
                      context: MetalContext, description: String) {
        guard let snapshot = captureStack(layerStack: layerStack, selectionPath: selectionPath, scope: scope,
                                          context: context, description: description,
                                          sharingWith: scope == .everything ? lastStackSnapshot : nil) else { return }
        noteStackSize(layerStack)
        push(.stack(snapshot))
    }

    private var lastStackSnapshot: StackSnapshot? {
        for entry in undoStack.reversed() {
            if case .stack(let snapshot) = entry { return snapshot }
        }
        return nil
    }

    /// Block until the GPU has finished every snapshot copy and comparison so far.
    func waitForPendingWork() {
        pending.wait()
    }

    /// Save one rectangle of a layer BEFORE a stroke is merged into it.
    /// The copy is encoded into `commandBuffer`, so it runs ahead of whatever that buffer
    /// does to the layer next.
    ///
    /// - Parameters:
    ///   - source: where the pixels come from, if not the layer itself: a tool that has
    ///     already changed the layer passes the copy it took beforehand.
    ///   - heightSource: likewise for the layer's height map, which is saved whenever the
    ///     layer has one.
    func saveRegion(of layer: Layer, in layerStack: LayerStack, region: MTLScissorRect, from source: MTLTexture? = nil,
                    heightFrom heightSource: MTLTexture? = nil, context: MetalContext, description: String,
                    commandBuffer: MTLCommandBuffer) {
        guard let snapshot = captureRegion(of: layer, region: region, from: source, heightFrom: heightSource,
                                           context: context, description: description,
                                           commandBuffer: commandBuffer) else { return }
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
        let budget = min(stackBytes * wholeStackSnapshotsInBudget, memoryCap)
        while undoStack.count > 1, undoStack.count > maxUndoLevels || Self.bytes(of: undoStack) > budget {
            undoStack.removeFirst()
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
            // Restoring changes the pixels of exactly the layers the snapshot holds copies of,
            // so the step that reverses it needs copies of exactly those
            let copied = snapshot.layers.filter(\.isCopy).map(\.id)
            let current = captureStack(layerStack: layerStack, selectionPath: viewModel.selectionPath,
                                       scope: .layers(copied), context: context, description: snapshot.description)
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
            if let height = snapshot.height, let layerHeight = heightTexture(for: layer, context: context, commandBuffer: commandBuffer),
               let blit = commandBuffer.makeBlitCommandEncoder() {
                blit.copy(from: height,
                          sourceSlice: 0, sourceLevel: 0,
                          sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0),
                          sourceSize: MTLSize(width: snapshot.region.width, height: snapshot.region.height, depth: 1),
                          to: layerHeight,
                          destinationSlice: 0, destinationLevel: 0,
                          destinationOrigin: MTLOrigin(x: snapshot.region.x, y: snapshot.region.y, z: 0))
                blit.endEncoding()
            }
            commandBuffer.commit()
            return current.map(Entry.region)
        }
    }

    /// The layer's height map, made and cleared (in `commandBuffer`) if it has none.
    private func heightTexture(for layer: Layer, context: MetalContext, commandBuffer: MTLCommandBuffer) -> MTLTexture? {
        if let height = layer.heightTexture { return height }
        guard let height = makeTexture(like: layer.texture, pixelFormat: .r16Float, context: context) else { return nil }
        clear(height, commandBuffer: commandBuffer)
        layer.heightTexture = height
        return height
    }

    private func makeTexture(like source: MTLTexture, pixelFormat: MTLPixelFormat, context: MetalContext) -> MTLTexture? {
        let desc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: pixelFormat, width: source.width, height: source.height, mipmapped: false
        )
        desc.usage = [.shaderRead, .shaderWrite, .renderTarget]
        desc.storageMode = .private
        return context.device.makeTexture(descriptor: desc)
    }

    private func clear(_ texture: MTLTexture, commandBuffer: MTLCommandBuffer) {
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = texture
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].storeAction = .store
        pass.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
        commandBuffer.makeRenderCommandEncoder(descriptor: pass)?.endEncoding()
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
        Self.bytes(of: undoStack + redoStack)
    }

    /// Texture memory held by `entries`, counting a texture that snapshots share once.
    private static func bytes(of entries: [Entry]) -> Int {
        var seen = Set<ObjectIdentifier>()
        var total = 0
        func count(_ texture: MTLTexture?) {
            guard let texture, seen.insert(ObjectIdentifier(texture)).inserted else { return }
            total += texture.width * texture.height * (texture.pixelFormat == .r16Float ? 2 : 8)
        }
        for entry in entries {
            switch entry {
            case .stack(let snapshot):
                for layer in snapshot.layers where layer.isCopy {
                    count(layer.texture)
                    count(layer.height)
                }
            case .region(let snapshot):
                count(snapshot.texture)
                count(snapshot.height)
            }
        }
        return total
    }

    // MARK: - Snapshot Capture & Restore

    private func captureRegion(of layer: Layer, region: MTLScissorRect, from source: MTLTexture? = nil,
                               heightFrom heightSource: MTLTexture? = nil, context: MetalContext, description: String,
                               commandBuffer: MTLCommandBuffer) -> RegionSnapshot? {
        guard region.width > 0, region.height > 0 else { return nil }

        func copy(of texture: MTLTexture) -> MTLTexture? {
            let desc = MTLTextureDescriptor.texture2DDescriptor(
                pixelFormat: texture.pixelFormat, width: region.width, height: region.height, mipmapped: false
            )
            desc.usage = [.shaderRead]
            desc.storageMode = .private
            guard let copy = context.device.makeTexture(descriptor: desc),
                  let blit = commandBuffer.makeBlitCommandEncoder() else { return nil }
            blit.copy(from: texture,
                      sourceSlice: 0, sourceLevel: 0,
                      sourceOrigin: MTLOrigin(x: region.x, y: region.y, z: 0),
                      sourceSize: MTLSize(width: region.width, height: region.height, depth: 1),
                      to: copy,
                      destinationSlice: 0, destinationLevel: 0,
                      destinationOrigin: MTLOrigin(x: 0, y: 0, z: 0))
            blit.endEncoding()
            return copy
        }

        guard let pixels = copy(of: source ?? layer.texture) else { return nil }
        let height = (heightSource ?? layer.heightTexture).flatMap(copy(of:))
        return RegionSnapshot(layerID: layer.id, region: region, texture: pixels, height: height, description: description)
    }

    /// Every layer's settings, and copies of the pixels of the layers in `scope`; the rest
    /// are referenced. With `previous`, the copies are then compared on the GPU with that
    /// snapshot's, and a layer found unchanged shares the previous copy instead.
    private func captureStack(layerStack: LayerStack, selectionPath: CGPath?, scope: Scope, context: MetalContext,
                              description: String, sharingWith previous: StackSnapshot? = nil) -> StackSnapshot? {
        var layerSnapshots: [LayerSnapshot] = []

        for layer in layerStack.layers {
            let copies = scope.includes(layer.id)
            var texture = layer.texture
            var height = layer.heightTexture
            if copies {
                guard let textureCopy = copyTexture(layer.texture, context: context) else { return nil }
                texture = textureCopy
                height = layer.heightTexture.flatMap { copyTexture($0, context: context) }
            }
            layerSnapshots.append(LayerSnapshot(
                id: layer.id,
                name: layer.name,
                isVisible: layer.isVisible,
                isLocked: layer.isLocked,
                opacity: layer.opacity,
                blendMode: layer.blendMode,
                texture: texture,
                height: height,
                isCopy: copies
            ))
        }

        let snapshot = StackSnapshot(
            layers: layerSnapshots,
            activeLayerIndex: layerStack.activeLayerIndex,
            selectionPath: selectionPath?.copy(),
            description: description
        )
        if let previous { shareUnchangedLayers(of: snapshot, with: previous, context: context) }
        return snapshot
    }

    private func shareUnchangedLayers(of snapshot: StackSnapshot, with previous: StackSnapshot, context: MetalContext) {
        // Candidates: the same layer in both, the same size, and either both or neither thick
        var candidates: [(index: Int, texture: MTLTexture, height: MTLTexture?)] = []
        for (index, layer) in snapshot.layers.enumerated() where layer.isCopy {
            guard let match = previous.layers.first(where: { $0.id == layer.id }), match.isCopy,
                  match.texture.width == layer.texture.width, match.texture.height == layer.texture.height,
                  (match.height == nil) == (layer.height == nil) else { continue }
            candidates.append((index, match.texture, match.height))
        }
        guard !candidates.isEmpty,
              let flags = context.device.makeBuffer(length: candidates.count * 4, options: .storageModeShared),
              let commandBuffer = context.commandQueue.makeCommandBuffer(),
              let encoder = commandBuffer.makeComputeCommandEncoder() else { return }
        memset(flags.contents(), 0, candidates.count * 4)
        encoder.setComputePipelineState(context.texturesDifferPipelineState)
        for (slot, candidate) in candidates.enumerated() {
            let layer = snapshot.layers[candidate.index]
            for (a, b) in [(layer.texture, candidate.texture)] + (layer.height.flatMap { h in candidate.height.map { [(h, $0)] } } ?? []) {
                encoder.setTexture(a, index: 0)
                encoder.setTexture(b, index: 1)
                encoder.setBuffer(flags, offset: slot * 4, index: 0)
                encoder.dispatchThreads(MTLSize(width: a.width, height: a.height, depth: 1),
                                        threadsPerThreadgroup: MTLSize(width: 16, height: 16, depth: 1))
            }
        }
        encoder.endEncoding()

        pending.enter()
        commandBuffer.addCompletedHandler { [pending] _ in
            let differ = flags.contents().bindMemory(to: UInt32.self, capacity: candidates.count)
            let layers = snapshot.layers
            for (slot, candidate) in candidates.enumerated() where differ[slot] == 0 {
                let layer = layers[candidate.index]
                snapshot.replaceLayer(at: candidate.index, with: LayerSnapshot(
                    id: layer.id, name: layer.name, isVisible: layer.isVisible, isLocked: layer.isLocked,
                    opacity: layer.opacity, blendMode: layer.blendMode,
                    texture: candidate.texture, height: candidate.height, isCopy: true
                ))
            }
            pending.leave()
        }
        commandBuffer.commit()
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
                if snap.isCopy {
                    blitCopy(from: snap.texture, to: existing.texture, context: context)
                    restoreHeight(snap.height, to: existing, context: context)
                } else if existing.texture !== snap.texture {
                    // The layer object outlived its pixels (a merge gave it new ones): the
                    // referenced textures are the ones from back then, still as they were
                    existing.texture = snap.texture
                    existing.heightTexture = snap.height
                }
                newLayers.append(existing)
            } else if !snap.isCopy {
                // The layer was deleted; its textures are still as they were when it went
                let layer = Layer(id: snap.id, name: snap.name, texture: snap.texture)
                layer.heightTexture = snap.height
                layer.isVisible = snap.isVisible
                layer.isLocked = snap.isLocked
                layer.opacity = snap.opacity
                layer.blendMode = snap.blendMode
                newLayers.append(layer)
            } else {
                // Layer was deleted and this snapshot copied it — recreate it
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
                restoreHeight(snap.height, to: layer, context: context)
                newLayers.append(layer)
            }
        }

        layerStack.layers = newLayers
        layerStack.activeLayerIndex = min(snapshot.activeLayerIndex, newLayers.count - 1)
    }

    /// Put a snapshot's height map back on a layer: none means flat.
    private func restoreHeight(_ snapshot: MTLTexture?, to layer: Layer, context: MetalContext) {
        if let snapshot {
            guard let commandBuffer = context.commandQueue.makeCommandBuffer(),
                  let height = heightTexture(for: layer, context: context, commandBuffer: commandBuffer) else { return }
            commandBuffer.commit()
            blitCopy(from: snapshot, to: height, context: context)
        } else if let height = layer.heightTexture, let commandBuffer = context.commandQueue.makeCommandBuffer() {
            clear(height, commandBuffer: commandBuffer)
            commandBuffer.commit()
        }
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
