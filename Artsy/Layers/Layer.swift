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

    var texture: MTLTexture
    @Published var thumbnail: NSImage?

    init(id: UUID = UUID(), name: String, texture: MTLTexture) {
        self.id = id
        self.name = name
        self.texture = texture
    }
}
