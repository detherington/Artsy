import Foundation
import Metal
import Foundation
import Combine
import CoreGraphics

public enum LayerBlendMode: String, Codable, CaseIterable, Identifiable {
    case normal
    case multiply
    case screen
    case overlay
    case darken
    case lighten

    public var id: String { rawValue }

    public var displayName: String {
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

public final class Layer: Identifiable, ObservableObject {
    public let id: UUID
    @Published public var name: String
    @Published public var isVisible: Bool = true
    @Published public var isLocked: Bool = false
    @Published public var opacity: Float = 1.0
    @Published public var blendMode: LayerBlendMode = .normal

    public let texture: MTLTexture
    /// Paint thickness per pixel (impasto), the same size as `texture`. Nil until a brush
    /// that lays thick paint has been used on the layer; whoever creates it clears it.
    public var heightTexture: MTLTexture?
    /// How wet the paint is, per pixel: the time until which it stays wet, in seconds
    /// since `wetEpoch` (half-float, the same size as `texture`). Nil until a brush that
    /// lays wet paint has been used on the layer; whoever creates it clears it. Not saved:
    /// a document opens dry.
    public var wetTexture: MTLTexture?
    /// The clock the wet map counts from: the renderer's clock when the map was made (or
    /// last started again, once the layer had dried all over).
    public var wetEpoch: TimeInterval = 0
    /// The latest time written into the wet map, seconds since `wetEpoch`: past it the
    /// layer is dry all over.
    public var wetUntil: TimeInterval = 0
    /// Water on the move, while a wash is spreading and drying; nil otherwise. See
    /// `LayerWater`: the layer's pixels show the look throughout.
    public var water: LayerWater?
    @Published public var thumbnail: CGImage?

    /// Whether any paint on the layer may still be wet at `now` (the renderer's clock).
    public func isWet(at now: TimeInterval) -> Bool {
        wetTexture != nil && now - wetEpoch < wetUntil
    }

    /// Dry the layer all over, at once: the paint stays where it is.
    public func dry() {
        wetTexture = nil
        wetUntil = 0
        settleWater()
    }

    /// Stop the water where it is. Call before writing the layer's pixels by any other
    /// means, so the flow does not write over them: the look the pixels hold stands.
    public func settleWater() {
        water = nil
    }

    public init(id: UUID = UUID(), name: String, texture: MTLTexture) {
        self.id = id
        self.name = name
        self.texture = texture
    }
}
