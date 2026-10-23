import Foundation
import Metal
import AppKit

enum LayerBlendMode: String, Codable, CaseIterable, Identifiable {
    case normal
    case multiply
    case screen
    case overlay
    case darken
    case lighten

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .normal: return "Normal"
        case .multiply: return "Multiply"
        case .screen: return "Screen"
        case .overlay: return "Overlay"
        case .darken: return "Darken"
        case .lighten: return "Lighten"
        }
    }
}

final class Layer: Identifiable, ObservableObject {
    let id: UUID
    @Published var name: String
    @Published var isVisible: Bool = true
    @Published var isLocked: Bool = false
    @Published var opacity: Float = 1.0
    @Published var blendMode: LayerBlendMode = .normal

    let texture: MTLTexture
    /// Paint thickness per pixel (impasto), the same size as `texture`. Nil until a brush
    /// that lays thick paint has been used on the layer; whoever creates it clears it.
    var heightTexture: MTLTexture?
    /// How wet the paint is, per pixel: the time until which it stays wet, in seconds
    /// since `wetEpoch` (half-float, the same size as `texture`). Nil until a brush that
    /// lays wet paint has been used on the layer; whoever creates it clears it. Not saved:
    /// a document opens dry.
    var wetTexture: MTLTexture?
    /// The clock the wet map counts from: the renderer's clock when the map was made (or
    /// last started again, once the layer had dried all over).
    var wetEpoch: TimeInterval = 0
    /// The latest time written into the wet map, seconds since `wetEpoch`: past it the
    /// layer is dry all over.
    var wetUntil: TimeInterval = 0
    @Published var thumbnail: NSImage?

    /// Whether any paint on the layer may still be wet at `now` (the renderer's clock).
    func isWet(at now: TimeInterval) -> Bool {
        wetTexture != nil && now - wetEpoch < wetUntil
    }

    /// Dry the layer all over, at once.
    func dry() {
        wetTexture = nil
        wetUntil = 0
    }

    init(id: UUID = UUID(), name: String, texture: MTLTexture) {
        self.id = id
        self.name = name
        self.texture = texture
    }
}
