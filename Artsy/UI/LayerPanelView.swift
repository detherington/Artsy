import SwiftUI
import UniformTypeIdentifiers

struct LayerPanelView: View {
    @ObservedObject var viewModel: CanvasViewModel
    @ObservedObject var layerStack: LayerStack
    @State private var draggingLayerID: UUID?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Add/delete buttons
            HStack(spacing: 6) {
                Spacer()
                Button(action: addLayer) {
                    Image(systemName: "plus")
                        .font(.system(size: 11, weight: .semibold))
                        .frame(width: 22, height: 22)
                        .background(RoundedRectangle(cornerRadius: 4).fill(Color(white: 0.22)))
                }
                .buttonStyle(.plain)
                .foregroundColor(.white)
                .disabled(layerStack.layers.count >= LayerStack.maxLayers)
                .help("Add layer")

                Button(action: deleteLayer) {
                    Image(systemName: "trash")
                        .font(.system(size: 11))
                        .frame(width: 22, height: 22)
                        .background(RoundedRectangle(cornerRadius: 4).fill(Color(white: 0.22)))
                }
                .buttonStyle(.plain)
                .foregroundColor(.white)
                .disabled(layerStack.layers.count <= 1)
                .help("Delete layer")
            }

            // Layer list — top layer shown first (reversed order)
            VStack(spacing: 2) {
                ForEach(Array(layerStack.layers.enumerated().reversed()), id: \.element.id) { index, layer in
                    LayerRowView(
                        layer: layer,
                        isActive: index == layerStack.activeLayerIndex,
                        isDragging: draggingLayerID == layer.id,
                        onSelect: { layerStack.activeLayerIndex = index },
                        onToggleVisibility: { layer.isVisible.toggle() }
                    )
                    .onDrag {
                        draggingLayerID = layer.id
                        return NSItemProvider(object: layer.id.uuidString as NSString)
                    }
                    .onDrop(
                        of: [UTType.plainText],
                        delegate: LayerDropDelegate(
                            targetLayerID: layer.id,
                            layerStack: layerStack,
                            draggingLayerID: $draggingLayerID,
                            onDrop: { saveUndoSnapshot(description: "Reorder Layers") }
                        )
                    )
                }
            }

            // Blend mode and opacity for active layer
            if let activeLayer = layerStack.activeLayer {
                Divider().padding(.vertical, 2)
                SectionLabel("Blend Mode")
                Picker("", selection: Binding(
                    get: { activeLayer.blendMode },
                    set: { activeLayer.blendMode = $0 }
                )) {
                    ForEach(LayerBlendMode.allCases) { mode in
                        Text(mode.displayName).tag(mode)
                    }
                }
                .pickerStyle(.menu)
                .labelsHidden()

                HStack {
                    Text("Opacity")
                        .font(.system(size: 11))
                        .foregroundColor(Color(white: 0.75))
                    Slider(value: Binding(
                        get: { activeLayer.opacity },
                        set: { activeLayer.opacity = $0 }
                    ), in: 0...1)
                    Text("\(Int(activeLayer.opacity * 100))%")
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundColor(Color(white: 0.55))
                        .frame(width: 36, alignment: .trailing)
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 4)
    }

    private func saveUndoSnapshot(description: String) {
        if let appDelegate = NSApp.delegate as? AppDelegate,
           let store = appDelegate.activeStorePublic {
            viewModel.saveUndoSnapshot(renderer: store.canvasView.renderer, description: description)
        }
    }

    private func addLayer() {
        saveUndoSnapshot(description: "Add Layer")
        try? layerStack.addLayer(above: layerStack.activeLayerIndex)
        if let appDelegate = NSApp.delegate as? AppDelegate,
           let store = appDelegate.activeStorePublic,
           let newLayer = layerStack.activeLayer {
            store.canvasView.renderer.updateThumbnail(for: newLayer)
        }
    }

    private func deleteLayer() {
        saveUndoSnapshot(description: "Delete Layer")
        _ = layerStack.removeLayer(at: layerStack.activeLayerIndex)
    }
}

// MARK: - Drop Delegate

struct LayerDropDelegate: DropDelegate {
    let targetLayerID: UUID
    let layerStack: LayerStack
    @Binding var draggingLayerID: UUID?
    let onDrop: () -> Void

    func validateDrop(info: DropInfo) -> Bool {
        guard let draggingID = draggingLayerID, draggingID != targetLayerID else { return false }
        return true
    }

    func dropEntered(info: DropInfo) {
        guard let draggingID = draggingLayerID, draggingID != targetLayerID else { return }
        guard let fromIndex = layerStack.layers.firstIndex(where: { $0.id == draggingID }),
              let toIndex = layerStack.layers.firstIndex(where: { $0.id == targetLayerID }) else { return }

        if fromIndex != toIndex {
            withAnimation(.easeInOut(duration: 0.2)) {
                layerStack.moveLayer(from: fromIndex, to: toIndex)
            }
        }
    }

    func performDrop(info: DropInfo) -> Bool {
        onDrop()
        draggingLayerID = nil
        return true
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        DropProposal(operation: .move)
    }
}

// MARK: - Layer Row

struct LayerRowView: View {
    @ObservedObject var layer: Layer
    let isActive: Bool
    let isDragging: Bool
    let onSelect: () -> Void
    let onToggleVisibility: () -> Void

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "line.3.horizontal")
                .font(.system(size: 9))
                .foregroundColor(Color(white: 0.4))
                .frame(width: 10)

            Button(action: onToggleVisibility) {
                Image(systemName: layer.isVisible ? "eye" : "eye.slash")
                    .font(.system(size: 10))
                    .foregroundColor(layer.isVisible ? .white : .gray)
                    .frame(width: 16)
            }
            .buttonStyle(.plain)

            // Layer thumbnail
            ZStack {
                RoundedRectangle(cornerRadius: 2)
                    .fill(Color(white: 0.25))
                if let thumb = layer.thumbnail {
                    Image(nsImage: thumb)
                        .resizable()
                        .interpolation(.low)
                        .aspectRatio(contentMode: .fit)
                        .cornerRadius(2)
                }
            }
            .frame(width: 32, height: 24)
            .overlay(
                RoundedRectangle(cornerRadius: 2)
                    .stroke(Color(white: 0.4), lineWidth: 0.5)
            )

            Text(layer.name)
                .font(.system(size: 11, weight: isActive ? .medium : .regular))
                .foregroundColor(.white)
                .lineLimit(1)

            Spacer()
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 4)
        .background(
            RoundedRectangle(cornerRadius: 4)
                .fill(isActive ? Color.accentColor.opacity(0.2) : Color.clear)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 4)
                .stroke(isActive ? Color.accentColor.opacity(0.5) : Color.clear, lineWidth: 0.5)
        )
        .opacity(isDragging ? 0.4 : 1.0)
        .contentShape(Rectangle())
        .onTapGesture { onSelect() }
    }
}
