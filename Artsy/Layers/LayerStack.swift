import Foundation
import Metal

final class LayerStack: ObservableObject {
    @Published var layers: [Layer] = []
    @Published var activeLayerIndex: Int = 0

    private let textureManager: TextureManager
    private let canvasWidth: Int
    private let canvasHeight: Int

    static let maxLayers = 8

    var activeLayer: Layer? {
        guard activeLayerIndex >= 0, activeLayerIndex < layers.count else { return nil }
        return layers[activeLayerIndex]
    }

    init(textureManager: TextureManager, canvasWidth: Int, canvasHeight: Int) {
        self.textureManager = textureManager
        self.canvasWidth = canvasWidth
        self.canvasHeight = canvasHeight
    }

    func createInitialLayer(commandBuffer: MTLCommandBuffer) throws {
        let layer = try makeLayer(name: "Background")
        // Fill background white
        textureManager.clearTexture(layer.texture, commandBuffer: commandBuffer,
            color: MTLClearColor(red: 1, green: 1, blue: 1, alpha: 1))
        layers.append(layer)

        let drawingLayer = try makeLayer(name: "Layer 1")
        layers.append(drawingLayer)
        activeLayerIndex = 1
    }

    func addLayer(above index: Int, name: String? = nil) throws -> Int {
        guard layers.count < LayerStack.maxLayers else {
            throw LayerError.maxLayersReached
        }
        let layerName = name ?? "Layer \(layers.count)"
        let layer = try makeLayer(name: layerName)
        let insertIndex = min(index + 1, layers.count)
        layers.insert(layer, at: insertIndex)
        activeLayerIndex = insertIndex
        return insertIndex
    }

    func removeLayer(at index: Int) -> (Layer, [Stroke])? {
        guard layers.count > 1, index >= 0, index < layers.count else { return nil }
        let layer = layers.remove(at: index)
        if activeLayerIndex >= layers.count {
            activeLayerIndex = layers.count - 1
        }
        return (layer, []) // strokes tracked separately in viewModel
    }

    func moveLayer(from: Int, to: Int) {
        guard from != to, from >= 0, from < layers.count, to >= 0, to < layers.count else { return }
        let layer = layers.remove(at: from)
        layers.insert(layer, at: to)
        // Update active index to follow the moved layer if needed
        if activeLayerIndex == from {
            activeLayerIndex = to
        } else if from < activeLayerIndex && to >= activeLayerIndex {
            activeLayerIndex -= 1
        } else if from > activeLayerIndex && to <= activeLayerIndex {
            activeLayerIndex += 1
        }
    }

    func mergeDown(at index: Int, renderer: CanvasRenderer) -> Bool {
        guard index > 0, index < layers.count else { return false }
        let upper = layers[index]
        let lower = layers[index - 1]

        guard let commandBuffer = renderer.context.commandQueue.makeCommandBuffer() else { return false }
        renderer.compositor.compositeNormal(
            source: upper.texture,
            onto: lower.texture,
            opacity: upper.opacity,
            commandBuffer: commandBuffer
        )
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()

        layers.remove(at: index)
        if activeLayerIndex >= layers.count {
            activeLayerIndex = layers.count - 1
        }
        return true
    }

    func flattenAll(renderer: CanvasRenderer) throws -> Layer {
        let result = try makeLayer(name: "Flattened")
        guard let commandBuffer = renderer.context.commandQueue.makeCommandBuffer() else {
            throw LayerError.flattenFailed
        }

        // Clear to white
        textureManager.clearTexture(result.texture, commandBuffer: commandBuffer,
            color: MTLClearColor(red: 1, green: 1, blue: 1, alpha: 1))

        for layer in layers where layer.isVisible {
            renderer.compositor.compositeNormal(
                source: layer.texture,
                onto: result.texture,
                opacity: layer.opacity,
                commandBuffer: commandBuffer
            )
        }
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()

        layers = [result]
        activeLayerIndex = 0
        return result
    }

    private func makeLayer(name: String) throws -> Layer {
        let texture = try textureManager.makeCanvasTexture(
            width: canvasWidth, height: canvasHeight, label: name
        )
        return Layer(name: name, texture: texture)
    }
}

enum LayerError: LocalizedError {
    case maxLayersReached
    case flattenFailed

    var errorDescription: String? {
        switch self {
        case .maxLayersReached: return "Maximum of \(LayerStack.maxLayers) layers reached"
        case .flattenFailed: return "Failed to flatten layers"
        }
    }
}
