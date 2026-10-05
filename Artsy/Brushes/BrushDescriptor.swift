import Foundation

struct BrushDescriptor: Codable, Identifiable, Equatable {
    let id: UUID
    let name: String
    let category: BrushCategory

    // Tip
    let hardness: Float       // 0.0 (soft gaussian) to 1.0 (hard edge)

    // Size
    let baseSize: Float       // Diameter the size slider starts at when this brush is first picked

    // Dynamics
    let pressureDynamics: PressureDynamics

    // Opacity
    let opacity: Float

    // Optional: fixed nib angle in radians for calligraphy-style brushes.
    // When set, the ribbon uses this fixed perpendicular direction instead of the
    // stroke-direction-based one, producing the classic thick/thin calligraphy effect.
    let fixedNibAngle: Float?

    // Shader selection
    var shaderType: BrushShaderType {
        // Use name to select specialized shaders
        switch name {
        case "Watercolor": return .watercolor
        case "Acrylic": return .acrylic
        case "Oil": return .oil
        case "Pencil", "Graphite Stick", "Conté", "Chalk", "Pastel": return .pencil
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

enum BrushShaderType {
    case procedural   // Hard/soft round via smoothstep
    case pencil       // Noise-textured
    case watercolor   // Soft edges with wet-edge darkening
    case acrylic      // Thick opaque with subtle texture
    case oil          // Impasto with pronounced bristles + canvas grain
}

// MARK: - Default Brushes

extension BrushDescriptor {
    static let hardRound = BrushDescriptor(
        id: UUID(uuidString: "00000000-0001-0000-0000-000000000001")!,
        name: "Hard Round",
        category: .inking,
        hardness: 1.0,
        baseSize: 12,
        pressureDynamics: PressureDynamics(
            sizeRange: 0.3...1.0,
            opacityRange: 1.0...1.0
        ),
        opacity: 1.0,
        fixedNibAngle: nil
    )

    static let softRound = BrushDescriptor(
        id: UUID(uuidString: "00000000-0002-0000-0000-000000000002")!,
        name: "Soft Round",
        category: .painting,
        hardness: 0.0,
        baseSize: 24,
        pressureDynamics: PressureDynamics(
            sizeRange: 0.5...1.0,
            opacityRange: 0.2...1.0
        ),
        opacity: 1.0,
        fixedNibAngle: nil
    )

    static let pencil = BrushDescriptor(
        id: UUID(uuidString: "00000000-0003-0000-0000-000000000003")!,
        name: "Pencil",
        category: .sketching,
        hardness: 0.7,
        baseSize: 8,
        pressureDynamics: PressureDynamics(
            sizeRange: 0.4...1.0,
            opacityRange: 0.3...0.9
        ),
        opacity: 0.9,
        fixedNibAngle: nil
    )

    static let inkBrush = BrushDescriptor(
        id: UUID(uuidString: "00000000-0004-0000-0000-000000000004")!,
        name: "Ink Brush",
        category: .inking,
        hardness: 0.9,
        baseSize: 16,
        pressureDynamics: PressureDynamics(
            sizeRange: 0.1...1.0,
            opacityRange: 0.5...1.0
        ),
        opacity: 1.0,
        fixedNibAngle: nil
    )

    static let marker = BrushDescriptor(
        id: UUID(uuidString: "00000000-0005-0000-0000-000000000005")!,
        name: "Marker",
        category: .painting,
        hardness: 0.3,
        baseSize: 32,
        pressureDynamics: PressureDynamics(
            sizeRange: 0.8...1.0,
            opacityRange: 0.6...0.9
        ),
        opacity: 0.7,
        fixedNibAngle: nil
    )

    static let watercolor = BrushDescriptor(
        id: UUID(uuidString: "00000000-0007-0000-0000-000000000007")!,
        name: "Watercolor",
        category: .painting,
        hardness: 0.0,
        baseSize: 40,
        pressureDynamics: PressureDynamics(
            sizeRange: 0.4...1.0,
            opacityRange: 0.3...0.8
        ),
        opacity: 0.7,
        fixedNibAngle: nil
    )

    static let acrylic = BrushDescriptor(
        id: UUID(uuidString: "00000000-0008-0000-0000-000000000008")!,
        name: "Acrylic",
        category: .painting,
        hardness: 0.15,      // Slightly soft edge but mostly opaque
        baseSize: 28,
        pressureDynamics: PressureDynamics(
            sizeRange: 0.5...1.0,
            opacityRange: 0.6...1.0   // Heavy coverage
        ),
        opacity: 0.9,
        fixedNibAngle: nil
    )

    static let technicalPen = BrushDescriptor(
        id: UUID(uuidString: "00000000-0009-0000-0000-000000000009")!,
        name: "Technical Pen",
        category: .inking,
        hardness: 1.0,
        baseSize: 3,
        pressureDynamics: PressureDynamics(
            sizeRange: 1.0...1.0,
            opacityRange: 1.0...1.0
        ),
        opacity: 1.0,
        fixedNibAngle: nil
    )

    static let ballpointPen = BrushDescriptor(
        id: UUID(uuidString: "00000000-000A-0000-0000-00000000000A")!,
        name: "Ballpoint",
        category: .inking,
        hardness: 0.85,
        baseSize: 2.5,
        pressureDynamics: PressureDynamics(
            sizeRange: 0.95...1.0,
            opacityRange: 0.55...1.0   // pressure drives opacity, not size
        ),
        opacity: 0.95,
        fixedNibAngle: nil
    )

    static let fineliner = BrushDescriptor(
        id: UUID(uuidString: "00000000-000B-0000-0000-00000000000B")!,
        name: "Fineliner",
        category: .inking,
        hardness: 0.95,
        baseSize: 4,
        pressureDynamics: PressureDynamics(
            sizeRange: 0.85...1.0,     // subtle pressure width response
            opacityRange: 0.85...1.0
        ),
        opacity: 1.0,
        fixedNibAngle: nil
    )

    static let gelPen = BrushDescriptor(
        id: UUID(uuidString: "00000000-000C-0000-0000-00000000000C")!,
        name: "Gel Pen",
        category: .inking,
        hardness: 0.8,          // slightly soft for the glossy-ink look
        baseSize: 5,
        pressureDynamics: PressureDynamics(
            sizeRange: 0.7...1.0,
            opacityRange: 0.85...1.0
        ),
        opacity: 1.0,
        fixedNibAngle: nil
    )

    static let graphiteStick = BrushDescriptor(
        id: UUID(uuidString: "00000000-000D-0000-0000-00000000000D")!,
        name: "Graphite Stick",
        category: .sketching,
        hardness: 0.5,
        baseSize: 26,         // much broader than pencil
        pressureDynamics: PressureDynamics(
            sizeRange: 0.55...1.0,
            opacityRange: 0.35...0.85
        ),
        opacity: 0.85,
        fixedNibAngle: nil
    )

    static let conte = BrushDescriptor(
        id: UUID(uuidString: "00000000-000E-0000-0000-00000000000E")!,
        name: "Conté",
        category: .sketching,
        hardness: 0.6,        // harder than pencil
        baseSize: 14,
        pressureDynamics: PressureDynamics(
            sizeRange: 0.5...1.0,
            opacityRange: 0.55...1.0   // darker base than pencil
        ),
        opacity: 0.95,
        fixedNibAngle: nil
    )

    static let oil = BrushDescriptor(
        id: UUID(uuidString: "00000000-0014-0000-0000-000000000014")!,
        name: "Oil",
        category: .painting,
        hardness: 0.6,          // firm-ish edge with slight softness
        baseSize: 30,
        pressureDynamics: PressureDynamics(
            sizeRange: 0.45...1.0,
            opacityRange: 0.7...1.0   // rich, heavy coverage
        ),
        opacity: 0.95,
        fixedNibAngle: nil
    )

    static let airbrush = BrushDescriptor(
        id: UUID(uuidString: "00000000-000F-0000-0000-00000000000F")!,
        name: "Airbrush",
        category: .painting,
        hardness: 0.0,         // maximally soft gaussian falloff
        baseSize: 48,
        pressureDynamics: PressureDynamics(
            sizeRange: 0.9...1.0,
            opacityRange: 0.08...0.5   // faint per stroke; layer strokes to build up
        ),
        opacity: 0.5,
        fixedNibAngle: nil
    )

    static let chalk = BrushDescriptor(
        id: UUID(uuidString: "00000000-0010-0000-0000-000000000010")!,
        name: "Chalk",
        category: .sketching,
        hardness: 0.35,        // softish edge; grain comes from pencil shader
        baseSize: 20,
        pressureDynamics: PressureDynamics(
            sizeRange: 0.5...1.0,
            opacityRange: 0.35...0.85
        ),
        opacity: 0.8,
        fixedNibAngle: nil
    )

    static let pastel = BrushDescriptor(
        id: UUID(uuidString: "00000000-0011-0000-0000-000000000011")!,
        name: "Pastel",
        category: .sketching,
        hardness: 0.2,         // very soft, very grainy — reuses pencil noise shader
        baseSize: 30,
        pressureDynamics: PressureDynamics(
            sizeRange: 0.55...1.0,
            opacityRange: 0.25...0.7
        ),
        opacity: 0.7,
        fixedNibAngle: nil
    )

    static let sumiE = BrushDescriptor(
        id: UUID(uuidString: "00000000-0012-0000-0000-000000000012")!,
        name: "Sumi-e",
        category: .inking,
        hardness: 0.55,        // softer than Ink Brush for ink-bleed feel
        baseSize: 24,
        pressureDynamics: PressureDynamics(
            sizeRange: 0.05...1.0,  // huge range = expressive tapered strokes
            opacityRange: 0.35...1.0
        ),
        opacity: 1.0,
        fixedNibAngle: nil
    )

    static let calligraphy = BrushDescriptor(
        id: UUID(uuidString: "00000000-0013-0000-0000-000000000013")!,
        name: "Calligraphy",
        category: .inking,
        hardness: 1.0,         // crisp edges, like a nib pen
        baseSize: 14,
        pressureDynamics: PressureDynamics(
            sizeRange: 0.8...1.0,
            opacityRange: 1.0...1.0
        ),
        opacity: 1.0,
        fixedNibAngle: Float.pi / 4   // 45° nib — classic italic angle
    )

    static let eraser = BrushDescriptor(
        id: UUID(uuidString: "00000000-0006-0000-0000-000000000006")!,
        name: "Eraser",
        category: .utility,
        hardness: 0.8,
        baseSize: 24,
        pressureDynamics: PressureDynamics(
            sizeRange: 0.5...1.0,
            opacityRange: 0.5...1.0
        ),
        opacity: 1.0,
        fixedNibAngle: nil
    )

    static let allDefaults: [BrushDescriptor] = [
        // Sketching
        .pencil, .graphiteStick, .conte, .chalk, .pastel,
        // Inking
        .hardRound, .inkBrush, .sumiE, .calligraphy,
        .technicalPen, .fineliner, .ballpointPen, .gelPen,
        // Painting
        .softRound, .airbrush, .marker, .watercolor, .acrylic, .oil
    ]

    /// Look up a built-in brush (including the eraser) by its display name.
    static func builtIn(named name: String) -> BrushDescriptor? {
        (allDefaults + [eraser]).first { $0.name == name }
    }
}
