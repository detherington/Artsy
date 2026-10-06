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

    // Stroke
    let smoothing: Float      // Smoothing amount this brush starts with (0.0-1.0)

    // Optional: fixed nib angle in radians for calligraphy-style brushes.
    // When set, the ribbon uses this fixed perpendicular direction instead of the
    // stroke-direction-based one, producing the classic thick/thin calligraphy effect.
    let fixedNibAngle: Float?

    /// How the stroke is drawn.
    var rendering: BrushRendering = .ribbon(.procedural)
}

/// The two ways a stroke can be drawn.
enum BrushRendering: Codable, Equatable {
    /// One continuous strip along the path, with a procedural cross-section. Crisp and
    /// free of dab artifacts: the right tool for pens and inks.
    case ribbon(RibbonShader)
    /// Many overlapping copies of a tip (dabs) laid along the path, the way paint programs
    /// model real media: texture, build-up and scatter all come from the dabs.
    case stamp(StampSettings)
}

enum BrushCategory: String, Codable, CaseIterable {
    case sketching
    case inking
    case painting
    case utility
}

enum RibbonShader: String, Codable {
    case procedural   // Hard/soft round via smoothstep
    case watercolor   // Soft edges with wet-edge darkening
    case acrylic      // Thick opaque with subtle texture
    case oil          // Impasto with pronounced bristles + canvas grain
}

/// Settings for a brush drawn with dabs.
struct StampSettings: Codable, Equatable {
    /// The shape of one dab.
    enum Tip: String, Codable {
        /// A disc whose edge softness comes from the brush's `hardness`.
        case round
        /// A rough-edged, blotchy disc, like the end of a stick of chalk.
        case chalk
    }

    /// How dabs add up within one stroke.
    enum Accumulation: String, Codable {
        /// Dabs build towards the stroke's opacity and stop there, so going back over
        /// part of a stroke without lifting does not darken it past that.
        case wash
        /// Every dab adds to what is already there, with no cap.
        case buildUp
    }

    /// How the paper's tooth shows through.
    struct Grain: Codable, Equatable {
        enum Mode: String, Codable {
            /// The grain modulates each dab's coverage.
            case multiply
            /// Light pressure only reaches the paper's peaks; firmer pressure fills the
            /// valleys too. This is what makes graphite and chalk look dry.
            case height
        }
        var mode: Mode
        /// Paper texture pixels per canvas pixel: larger is finer.
        var scale: Float
        /// 0 (no grain) to 1 (strongest). For `height`, the pressure it takes to reach
        /// the paper's deepest valleys.
        var depth: Float
    }

    var tip: Tip = .round
    /// Distance between dabs, as a fraction of the dab's diameter.
    var spacing: Float
    /// Opacity of a single dab, before pressure.
    var flow: Float
    var accumulation: Accumulation = .wash
    var grain: Grain? = nil
    /// Random variation per dab, each 0 (none) to 1.
    var sizeJitter: Float = 0
    var opacityJitter: Float = 0
    /// Random rotation per dab, as a fraction of a full turn.
    var angleJitter: Float = 0
    /// Random offset per dab, as a fraction of its diameter.
    var scatter: Float = 0
    /// Turn each dab to face along the stroke.
    var followsDirection: Bool = false
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
        smoothing: 0.3,
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
            opacityRange: 0.2...1.0    // pressure drives flow
        ),
        opacity: 1.0,
        smoothing: 0.4,
        fixedNibAngle: nil,
        // Close spacing so a full-pressure stroke builds to (nearly) its full opacity
        // along the middle while each dab stays faint enough to keep the edge soft.
        rendering: .stamp(StampSettings(spacing: 0.06, flow: 0.3))
    )

    static let pencil = BrushDescriptor(
        id: UUID(uuidString: "00000000-0003-0000-0000-000000000003")!,
        name: "Pencil",
        category: .sketching,
        hardness: 0.55,
        baseSize: 8,
        pressureDynamics: PressureDynamics(
            sizeRange: 0.5...1.0,
            opacityRange: 0.2...0.85   // a light touch only catches the paper's peaks; even a
                                       // firm one leaves the deepest valleys bare
        ),
        opacity: 0.9,
        smoothing: 0.2,
        fixedNibAngle: nil,
        rendering: .stamp(StampSettings(
            spacing: 0.12, flow: 0.3, accumulation: .buildUp,
            grain: .init(mode: .height, scale: 2.2, depth: 0.9),
            sizeJitter: 0.1, opacityJitter: 0.15
        ))
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
        smoothing: 0.5,
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
        smoothing: 0.3,
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
        smoothing: 0.4,
        fixedNibAngle: nil,
        rendering: .ribbon(.watercolor)
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
        smoothing: 0.3,
        fixedNibAngle: nil,
        rendering: .ribbon(.acrylic)
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
        smoothing: 0.5,
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
        smoothing: 0.4,
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
        smoothing: 0.45,
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
        smoothing: 0.35,
        fixedNibAngle: nil
    )

    static let graphiteStick = BrushDescriptor(
        id: UUID(uuidString: "00000000-000D-0000-0000-00000000000D")!,
        name: "Graphite Stick",
        category: .sketching,
        hardness: 0.35,
        baseSize: 26,         // much broader than pencil
        pressureDynamics: PressureDynamics(
            sizeRange: 0.6...1.0,
            opacityRange: 0.15...0.9
        ),
        opacity: 0.85,
        smoothing: 0.25,
        fixedNibAngle: nil,
        rendering: .stamp(StampSettings(
            spacing: 0.08, flow: 0.25, accumulation: .buildUp,
            grain: .init(mode: .height, scale: 1.0, depth: 0.9),
            opacityJitter: 0.1
        ))
    )

    static let conte = BrushDescriptor(
        id: UUID(uuidString: "00000000-000E-0000-0000-00000000000E")!,
        name: "Conté",
        category: .sketching,
        hardness: 0.6,        // harder than pencil
        baseSize: 14,
        pressureDynamics: PressureDynamics(
            sizeRange: 0.6...1.0,
            opacityRange: 0.4...1.0   // darker base than pencil
        ),
        opacity: 0.95,
        smoothing: 0.2,
        fixedNibAngle: nil,
        rendering: .stamp(StampSettings(
            tip: .chalk, spacing: 0.1, flow: 0.6, accumulation: .buildUp,
            grain: .init(mode: .height, scale: 1.0, depth: 0.75),
            opacityJitter: 0.15, angleJitter: 1.0
        ))
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
        smoothing: 0.3,
        fixedNibAngle: nil,
        rendering: .ribbon(.oil)
    )

    static let airbrush = BrushDescriptor(
        id: UUID(uuidString: "00000000-000F-0000-0000-00000000000F")!,
        name: "Airbrush",
        category: .painting,
        hardness: 0.0,         // maximally soft gaussian falloff
        baseSize: 48,
        pressureDynamics: PressureDynamics(
            sizeRange: 0.9...1.0,      // nearly constant radius; pressure drives how much paint
            opacityRange: 0.15...1.0
        ),
        opacity: 1.0,
        smoothing: 0.3,
        fixedNibAngle: nil,
        // Faint dabs with no cap: paint keeps building as you go back over it.
        rendering: .stamp(StampSettings(spacing: 0.06, flow: 0.07, accumulation: .buildUp))
    )

    static let chalk = BrushDescriptor(
        id: UUID(uuidString: "00000000-0010-0000-0000-000000000010")!,
        name: "Chalk",
        category: .sketching,
        hardness: 0.35,
        baseSize: 20,
        pressureDynamics: PressureDynamics(
            sizeRange: 0.6...1.0,
            opacityRange: 0.3...1.0
        ),
        opacity: 0.9,
        smoothing: 0.2,
        fixedNibAngle: nil,
        rendering: .stamp(StampSettings(
            tip: .chalk, spacing: 0.1, flow: 0.5, accumulation: .buildUp,
            grain: .init(mode: .height, scale: 0.8, depth: 0.85),
            sizeJitter: 0.1, opacityJitter: 0.2, angleJitter: 1.0, scatter: 0.04
        ))
    )

    static let pastel = BrushDescriptor(
        id: UUID(uuidString: "00000000-0011-0000-0000-000000000011")!,
        name: "Pastel",
        category: .sketching,
        hardness: 0.2,
        baseSize: 30,
        pressureDynamics: PressureDynamics(
            sizeRange: 0.65...1.0,
            opacityRange: 0.25...1.0
        ),
        opacity: 0.85,
        smoothing: 0.25,
        fixedNibAngle: nil,
        // Softer and more even than chalk: the grain tints rather than breaks up the mark.
        rendering: .stamp(StampSettings(
            tip: .chalk, spacing: 0.08, flow: 0.35, accumulation: .buildUp,
            grain: .init(mode: .multiply, scale: 0.7, depth: 0.55),
            opacityJitter: 0.15, angleJitter: 1.0, scatter: 0.03
        ))
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
        smoothing: 0.6,
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
        smoothing: 0.4,
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
            // Erases fully at any pressure (a mouse reports 0.7); the Opacity slider is
            // the way to erase partially.
            opacityRange: 1.0...1.0
        ),
        opacity: 1.0,
        smoothing: 0.3,
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
