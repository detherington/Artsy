import Foundation

struct BrushDescriptor: Codable, Identifiable, Equatable {
    let id: UUID
    let name: String
    let category: BrushCategory

    // Tip
    let tipTextureName: String?
    let tipShape: TipShape
    let hardness: Float       // 0.0 (soft gaussian) to 1.0 (hard edge)

    // Size
    let baseSize: Float       // Base diameter in points (1-500)
    let minSize: Float        // Minimum size multiplier (0-1)

    // Dynamics
    let pressureDynamics: PressureDynamics
    let tiltEnabled: Bool
    let velocityEnabled: Bool

    // Stroke
    let spacing: Float        // Stamp spacing as fraction of size (0.05-1.0)
    let smoothing: Float      // Input smoothing amount (0.0-1.0)
    let blendMode: StrokeBlendMode

    // Opacity
    let opacity: Float
    let flow: Float
    let buildUp: Bool

    // Shader selection
    var shaderType: BrushShaderType {
        if tipTextureName != nil {
            return .textured
        }
        // Use name to select specialized shaders
        switch name {
        case "Watercolor": return .watercolor
        case "Acrylic": return .acrylic
        case "Pencil": return .pencil
        default: return .procedural
        }
    }
}

enum BrushCategory: String, Codable, CaseIterable {
    case sketching
    case inking
    case painting
    case utility
}

enum TipShape: String, Codable {
    case round
    case square
    case custom
}

enum StrokeBlendMode: String, Codable {
    case normal
    case multiply
    case screen
    case overlay
    case darken
    case lighten
}

enum BrushShaderType {
    case procedural   // Hard/soft round via smoothstep
    case pencil       // Noise-textured
    case textured     // External texture
    case watercolor   // Soft edges with wet-edge darkening
    case acrylic      // Thick opaque with subtle texture
}

// MARK: - Default Brushes

extension BrushDescriptor {
    static let hardRound = BrushDescriptor(
        id: UUID(uuidString: "00000000-0001-0000-0000-000000000001")!,
        name: "Hard Round",
        category: .inking,
        tipTextureName: nil,
        tipShape: .round,
        hardness: 1.0,
        baseSize: 12,
        minSize: 0.3,
        pressureDynamics: PressureDynamics(
            sizeRange: 0.3...1.0,
            opacityRange: 1.0...1.0,
            flowRange: 1.0...1.0
        ),
        tiltEnabled: false,
        velocityEnabled: false,
        spacing: 0.10,
        smoothing: 0.3,
        blendMode: .normal,
        opacity: 1.0,
        flow: 1.0,
        buildUp: false
    )

    static let softRound = BrushDescriptor(
        id: UUID(uuidString: "00000000-0002-0000-0000-000000000002")!,
        name: "Soft Round",
        category: .painting,
        tipTextureName: nil,
        tipShape: .round,
        hardness: 0.0,
        baseSize: 24,
        minSize: 0.5,
        pressureDynamics: PressureDynamics(
            sizeRange: 0.5...1.0,
            opacityRange: 0.2...1.0,
            flowRange: 0.3...1.0
        ),
        tiltEnabled: false,
        velocityEnabled: false,
        spacing: 0.15,
        smoothing: 0.4,
        blendMode: .normal,
        opacity: 1.0,
        flow: 0.8,
        buildUp: false
    )

    static let pencil = BrushDescriptor(
        id: UUID(uuidString: "00000000-0003-0000-0000-000000000003")!,
        name: "Pencil",
        category: .sketching,
        tipTextureName: nil,
        tipShape: .round,
        hardness: 0.7,
        baseSize: 8,
        minSize: 0.4,
        pressureDynamics: PressureDynamics(
            sizeRange: 0.4...1.0,
            opacityRange: 0.3...0.9,
            flowRange: 0.2...0.8
        ),
        tiltEnabled: true,
        velocityEnabled: false,
        spacing: 0.08,
        smoothing: 0.2,
        blendMode: .normal,
        opacity: 0.9,
        flow: 0.7,
        buildUp: true
    )

    static let inkBrush = BrushDescriptor(
        id: UUID(uuidString: "00000000-0004-0000-0000-000000000004")!,
        name: "Ink Brush",
        category: .inking,
        tipTextureName: nil,
        tipShape: .round,
        hardness: 0.9,
        baseSize: 16,
        minSize: 0.1,
        pressureDynamics: PressureDynamics(
            sizeRange: 0.1...1.0,
            opacityRange: 0.5...1.0,
            flowRange: 0.5...1.0
        ),
        tiltEnabled: false,
        velocityEnabled: true,
        spacing: 0.05,
        smoothing: 0.5,
        blendMode: .normal,
        opacity: 1.0,
        flow: 1.0,
        buildUp: false
    )

    static let marker = BrushDescriptor(
        id: UUID(uuidString: "00000000-0005-0000-0000-000000000005")!,
        name: "Marker",
        category: .painting,
        tipTextureName: nil,
        tipShape: .round,
        hardness: 0.3,
        baseSize: 32,
        minSize: 0.8,
        pressureDynamics: PressureDynamics(
            sizeRange: 0.8...1.0,
            opacityRange: 0.6...0.9,
            flowRange: 0.5...0.8
        ),
        tiltEnabled: false,
        velocityEnabled: false,
        spacing: 0.20,
        smoothing: 0.3,
        blendMode: .normal,
        opacity: 0.7,
        flow: 0.6,
        buildUp: true
    )

    static let watercolor = BrushDescriptor(
        id: UUID(uuidString: "00000000-0007-0000-0000-000000000007")!,
        name: "Watercolor",
        category: .painting,
        tipTextureName: nil,
        tipShape: .round,
        hardness: 0.0,
        baseSize: 40,
        minSize: 0.4,
        pressureDynamics: PressureDynamics(
            sizeRange: 0.4...1.0,
            opacityRange: 0.3...0.8,
            flowRange: 0.3...0.8
        ),
        tiltEnabled: false,
        velocityEnabled: true,
        spacing: 0.08,
        smoothing: 0.4,
        blendMode: .normal,
        opacity: 0.7,
        flow: 0.6,
        buildUp: true
    )

    static let acrylic = BrushDescriptor(
        id: UUID(uuidString: "00000000-0008-0000-0000-000000000008")!,
        name: "Acrylic",
        category: .painting,
        tipTextureName: nil,
        tipShape: .round,
        hardness: 0.15,      // Slightly soft edge but mostly opaque
        baseSize: 28,
        minSize: 0.5,
        pressureDynamics: PressureDynamics(
            sizeRange: 0.5...1.0,
            opacityRange: 0.6...1.0,   // Heavy coverage
            flowRange: 0.5...1.0
        ),
        tiltEnabled: false,
        velocityEnabled: false,
        spacing: 0.06,
        smoothing: 0.3,
        blendMode: .normal,
        opacity: 0.9,
        flow: 0.85,
        buildUp: false
    )

    static let eraser = BrushDescriptor(
        id: UUID(uuidString: "00000000-0006-0000-0000-000000000006")!,
        name: "Eraser",
        category: .utility,
        tipTextureName: nil,
        tipShape: .round,
        hardness: 0.8,
        baseSize: 24,
        minSize: 0.5,
        pressureDynamics: PressureDynamics(
            sizeRange: 0.5...1.0,
            opacityRange: 0.5...1.0,
            flowRange: 1.0...1.0
        ),
        tiltEnabled: false,
        velocityEnabled: false,
        spacing: 0.10,
        smoothing: 0.3,
        blendMode: .normal,
        opacity: 1.0,
        flow: 1.0,
        buildUp: false
    )

    static let allDefaults: [BrushDescriptor] = [
        .hardRound, .softRound, .pencil, .inkBrush, .marker, .watercolor, .acrylic
    ]
}
