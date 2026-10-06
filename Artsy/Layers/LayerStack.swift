import Foundation
import Metal

final class LayerStack: ObservableObject {
    @Published var layers: [Layer] = []
    @Published var activeLayerIndex: Int = 0

    private let textureManager: TextureManager
    private let canvasWidth: Int
    private let canvasHeight: Int

    /// The most layers any canvas may have.
    static let maxLayers = 32
    /// Memory to size the layer limit by, in place of the device's; for tests.
    var memoryBudgetOverride: Int?

    /// Layers this canvas may have: up to `maxLayers`, fewer when more would not fit in
    /// memory. A layer costs 8 bytes a pixel (plus 2 for thick paint), and undo history and
    /// the stroke textures need room beside the layers.
    var layerLimit: Int {
        Self.layerLimit(forCanvasPixels: canvasWidth * canvasHeight,
                        memoryBudget: memoryBudgetOverride ?? textureManager.memoryBudget)
    }

    static func layerLimit(forCanvasPixels pixels: Int, memoryBudget: Int) -> Int {
        // Half the budget for the layers themselves
        max(2, min(maxLayers, memoryBudget / 2 / (pixels * 10)))
    }

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
        guard layers.count < layerLimit else {
            throw LayerError.maxLayersReached(layerLimit)
        }
        let layerName = name ?? "Layer \(layers.count)"
        let layer = try makeLayer(name: layerName)
        let insertIndex = min(index + 1, layers.count)
        layers.insert(layer, at: insertIndex)
        activeLayerIndex = insertIndex
        return insertIndex
    }

    @discardableResult
    func removeLayer(at index: Int) -> Layer? {
        guard layers.count > 1, index >= 0, index < layers.count else { return nil }
        let layer = layers.remove(at: index)
        if activeLayerIndex >= layers.count {
            activeLayerIndex = layers.count - 1
        }
        return layer
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
        // Thick paint on top of thick paint adds up
        if let upperHeight = upper.heightTexture,
           let lowerHeight = renderer.heightTexture(for: lower, commandBuffer: commandBuffer) {
            renderer.compositor.accumulateHeight(source: upperHeight, onto: lowerHeight, opacity: upper.opacity,
                                                 commandBuffer: commandBuffer)
        }
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()

        layers.remove(at: index)
        if activeLayerIndex >= layers.count {
            activeLayerIndex = layers.count - 1
        }
        renderer.viewModel?.noteContentChanged()
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
            if let height = layer.heightTexture,
               let resultHeight = renderer.heightTexture(for: result, commandBuffer: commandBuffer) {
                renderer.compositor.accumulateHeight(source: height, onto: resultHeight, opacity: layer.opacity,
                                                     commandBuffer: commandBuffer)
            }
        }
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()

        layers = [result]
        activeLayerIndex = 0
        renderer.viewModel?.noteContentChanged()
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
    case maxLayersReached(Int)
    case flattenFailed

    var errorDescription: String? {
        switch self {
        case .maxLayersReached(let limit):
            return limit < LayerStack.maxLayers
                ? "A canvas this size can have \(limit) layers in this Mac's memory"
                : "Maximum of \(limit) layers reached"
        case .flattenFailed: return "Failed to flatten layers"
        }
    }
}
