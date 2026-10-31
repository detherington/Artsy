#if canImport(AppKit)
import AppKit
#endif
import SwiftUI
import UniformTypeIdentifiers
import ArtsyEngine

/// What the layers dock and pop-up share: the selected layer's blend mode and opacity,
/// the buttons that add, duplicate, merge and delete, and the list — rows a pen can hit,
/// each with its thumbnail, name, visibility and lock, dragged by their handle to reorder,
/// held for a menu.
struct LayersPanelContent: View {
    @ObservedObject var viewModel: CanvasViewModel
    @ObservedObject var layerStack: LayerStack
    let renderer: CanvasRenderer?
    @State private var draggingLayerID: UUID?
    /// Whether this drag has saved its "Reorder Layers" step yet.
    @State private var reorderStepSaved = false

    static let rowHeight: CGFloat = 48
    static let handleWidth: CGFloat = 40

    private var actions: LayerActions { LayerActions(viewModel: viewModel, layerStack: layerStack, renderer: renderer) }

    var body: some View {
        VStack(spacing: 0) {
            if let active = layerStack.activeLayer {
                LayerControls(layer: active, actions: actions)
                Divider().overlay(Chrome.hairline)
            }
            buttons
            Divider().overlay(Chrome.hairline)
            DragScroll(dragHandleWidth: Self.handleWidth) {
                VStack(spacing: 2) {
                    // The top layer first
                    ForEach(Array(layerStack.layers.enumerated().reversed()), id: \.element.id) { index, layer in
                        LayerRow(
                            layer: layer,
                            isActive: index == layerStack.activeLayerIndex,
                            isDragging: draggingLayerID == layer.id,
                            canMergeDown: index > 0,
                            canDelete: layerStack.layers.count > 1,
                            select: { actions.select(index) },
                            toggleVisibility: { actions.toggleVisibility(of: layer) },
                            toggleLock: { actions.toggleLock(of: layer) },
                            duplicate: { actions.duplicate(at: index) },
                            mergeDown: { actions.mergeDown(at: index) },
                            delete: { actions.delete(at: index) }
                        )
                        .onDrag {
                            draggingLayerID = layer.id
                            reorderStepSaved = false
                            return NSItemProvider(object: layer.id.uuidString as NSString)
                        }
                        .onDrop(of: [UTType.plainText], delegate: LayerDropDelegate(
                            targetLayerID: layer.id, layerStack: layerStack, draggingLayerID: $draggingLayerID,
                            // The order changes as the drag passes rows; the step is saved before
                            // the first of those, once per drag
                            onBeforeFirstMove: {
                                guard !reorderStepSaved else { return }
                                reorderStepSaved = true
                                actions.saveStep("Reorder Layers")
                            }
                        ))
                    }
                }
                .padding(.vertical, 6)
            }
        }
    }

    private var buttons: some View {
        let count = layerStack.layers.count
        return HStack(spacing: 0) {
            Spacer()
            ChromeButton(systemImage: "plus", label: "Add", help: "Add a layer above this one") { actions.add() }
                .disabled(count >= layerStack.layerLimit)
            Spacer()
            ChromeButton(systemImage: "plus.square.on.square", label: "Copy", help: "Duplicate this layer") {
                actions.duplicate(at: layerStack.activeLayerIndex)
            }
            .disabled(count >= layerStack.layerLimit)
            Spacer()
            ChromeButton(systemImage: "arrow.down.to.line.compact", label: "Merge", help: "Merge this layer into the one below") {
                actions.mergeDown(at: layerStack.activeLayerIndex)
            }
            .disabled(layerStack.activeLayerIndex == 0)
            Spacer()
            ChromeButton(systemImage: "trash", label: "Delete", help: "Delete this layer") {
                actions.delete(at: layerStack.activeLayerIndex)
            }
            .disabled(count <= 1)
            Spacer()
        }
        .frame(height: 52)
    }
}

/// The selected layer's blend mode and opacity, above the list.
struct LayerControls: View {
    @ObservedObject var layer: Layer
    let actions: LayerActions

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Text("blend")
                    .font(Chrome.sectionFont)
                    .tracking(Chrome.sectionTracking)
                    .foregroundColor(Chrome.secondaryText)
                    .frame(width: 64, alignment: .leading)
                Picker("", selection: Binding(get: { layer.blendMode }, set: { actions.setBlendMode($0, of: layer) })) {
                    ForEach(LayerBlendMode.allCases) { mode in
                        Text(mode.displayName).tag(mode)
                    }
                }
                .pickerStyle(.menu)
                .labelsHidden()
                .controlSize(.large)
                Spacer()
            }
            .padding(.horizontal, 14)
            .frame(height: Chrome.target)
            PanelSlider("Opacity", value: Binding(get: { layer.opacity }, set: { layer.opacity = $0 }), range: 0...1,
                        onEditingChanged: { began in if began { actions.saveStep("Layer Opacity") } }) {
                "\(Int(($0 * 100).rounded()))%"
            }
        }
    }
}

/// A layer in the list: its handle, thumbnail, name, visibility and lock.
struct LayerRow: View {
    @ObservedObject var layer: Layer
    let isActive: Bool
    let isDragging: Bool
    let canMergeDown: Bool
    let canDelete: Bool
    let select: () -> Void
    let toggleVisibility: () -> Void
    let toggleLock: () -> Void
    let duplicate: () -> Void
    let mergeDown: () -> Void
    let delete: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "line.3.horizontal")
                .font(.system(size: 12))
                .foregroundColor(Chrome.secondaryText.opacity(0.7))
                .frame(width: 24, height: LayersPanelContent.rowHeight)
                .help("Drag to reorder")
            ZStack {
                Rectangle().fill(Chrome.control)
                if let thumb = layer.thumbnail {
                    Image(decorative: thumb, scale: 1)
                        .resizable()
                        .interpolation(.low)
                        .aspectRatio(contentMode: .fit)
                }
            }
            .frame(width: 44, height: 32)
            .overlay(Rectangle().stroke(Chrome.hairline, lineWidth: 1))
            Text(layer.name)
                .font(Chrome.font)
                .foregroundColor(isActive ? Chrome.text : Chrome.secondaryText)
                .lineLimit(1)
            Spacer(minLength: 4)
            rowButton(layer.isVisible ? "eye" : "eye.slash", on: layer.isVisible, help: layer.isVisible ? "Hide" : "Show",
                      action: toggleVisibility)
            rowButton(layer.isLocked ? "lock.fill" : "lock.open", on: layer.isLocked, help: layer.isLocked ? "Unlock" : "Lock",
                      action: toggleLock)
        }
        .padding(.leading, 6)
        .padding(.trailing, 6)
        .frame(height: LayersPanelContent.rowHeight)
        .background(Rectangle().fill(isActive ? Chrome.selected : Color.clear))
        .overlay(alignment: .leading) {
            if isActive { Mark().padding(.leading, 2) }
        }
        .opacity(isDragging ? 0.4 : 1)
        .padding(.horizontal, 6)
        .contentShape(Rectangle())
        .onTapGesture(perform: select)
        .contextMenu {
            Button("Duplicate", action: duplicate)
            Button("Merge Down", action: mergeDown).disabled(!canMergeDown)
            Divider()
            Button("Delete", action: delete).disabled(!canDelete)
        }
    }

    private func rowButton(_ systemImage: String, on: Bool, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 14))
                .frame(width: 36, height: 36)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundColor(on ? Chrome.text : Chrome.secondaryText.opacity(0.7))
        .help(help)
    }
}

/// What the panel does to layers, each with its undo step, apart from the views so it can
/// be tested without them. Without a renderer there is no undo and nothing that needs the
/// GPU (merge, duplicate).
struct LayerActions {
    let viewModel: CanvasViewModel
    let layerStack: LayerStack
    let renderer: CanvasRenderer?

    /// An undo step for what is about to change: the layers whose pixels will, or none for
    /// order, settings, adding and deleting.
    func saveStep(_ description: String, changing scope: CanvasUndoManager.Scope = .nothing) {
        guard let renderer else { return }
        // A transform in progress lands on its layer before the layer list changes
        ChromeActions.commitPendingEdits()
        viewModel.saveUndoSnapshot(renderer: renderer, description: description, changing: scope)
    }

    func select(_ index: Int) {
        guard layerStack.layers.indices.contains(index) else { return }
        layerStack.activeLayerIndex = index
    }

    func add() {
        saveStep("Add Layer")
        guard (try? layerStack.addLayer(above: layerStack.activeLayerIndex)) != nil, let layer = layerStack.activeLayer else { return }
        renderer?.updateThumbnail(for: layer)
    }

    func duplicate(at index: Int) {
        guard let renderer else { return }
        saveStep("Duplicate Layer")
        _ = try? layerStack.duplicateLayer(at: index, renderer: renderer)
    }

    func mergeDown(at index: Int) {
        guard let renderer, index > 0, index < layerStack.layers.count else { return }
        // The lower layer's pixels change; the upper one goes, and comes back from the step
        saveStep("Merge Down", changing: .layers([layerStack.layers[index - 1].id]))
        guard layerStack.mergeDown(at: index, renderer: renderer) else { return }
        renderer.updateThumbnail(for: layerStack.layers[index - 1])
    }

    func delete(at index: Int) {
        guard layerStack.layers.count > 1, layerStack.layers.indices.contains(index) else { return }
        saveStep("Delete Layer")
        layerStack.removeLayer(at: index)
        viewModel.noteContentChanged()
    }

    func toggleVisibility(of layer: Layer) {
        saveStep(layer.isVisible ? "Hide Layer" : "Show Layer")
        layer.isVisible.toggle()
    }

    func toggleLock(of layer: Layer) {
        saveStep(layer.isLocked ? "Unlock Layer" : "Lock Layer")
        layer.isLocked.toggle()
    }

    func setBlendMode(_ mode: LayerBlendMode, of layer: Layer) {
        guard mode != layer.blendMode else { return }
        saveStep("Blend Mode")
        layer.blendMode = mode
    }
}

/// Reordering by drag: as the dragged row passes another, they swap places.
struct LayerDropDelegate: DropDelegate {
    let targetLayerID: UUID
    let layerStack: LayerStack
    @Binding var draggingLayerID: UUID?
    let onBeforeFirstMove: () -> Void

    func validateDrop(info: DropInfo) -> Bool {
        guard let draggingID = draggingLayerID, draggingID != targetLayerID else { return false }
        return true
    }

    func dropEntered(info: DropInfo) {
        guard let draggingID = draggingLayerID, draggingID != targetLayerID else { return }
        guard let fromIndex = layerStack.layers.firstIndex(where: { $0.id == draggingID }),
              let toIndex = layerStack.layers.firstIndex(where: { $0.id == targetLayerID }) else { return }
        if fromIndex != toIndex {
            onBeforeFirstMove()
            withAnimation(.easeInOut(duration: 0.2)) {
                layerStack.moveLayer(from: fromIndex, to: toIndex)
            }
        }
    }

    func performDrop(info: DropInfo) -> Bool {
        draggingLayerID = nil
        return true
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        DropProposal(operation: .move)
    }
}
