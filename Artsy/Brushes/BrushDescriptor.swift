import Foundation

/// Everything that defines a brush. Built-in brushes are the static members below; the
/// user's own live in `BrushLibrary` as the same type, saved as JSON.
struct BrushDescriptor: Codable, Identifiable, Equatable {
    private(set) var id: UUID
    var name: String
    var category: BrushCategory

    // Tip
    var hardness: Float       // 0.0 (soft gaussian) to 1.0 (hard edge)

    // Size
    var baseSize: Float       // Diameter the size slider starts at when this brush is first picked

    // Dynamics
    var pressureDynamics: PressureDynamics

    // Opacity
    var opacity: Float

    // Stroke
    var smoothing: Float      // Smoothing amount this brush starts with (0.0-1.0)

    // Optional: fixed nib angle in radians for calligraphy-style brushes.
    // When set, the ribbon uses this fixed perpendicular direction instead of the
    // stroke-direction-based one, producing the classic thick/thin calligraphy effect.
    var fixedNibAngle: Float?

    /// How the stroke is drawn.
    var rendering: BrushRendering = .ribbon(.procedural)

    /// Response to the pen leaning over; nil ignores tilt.
    var tiltDynamics: TiltDynamics? = nil
    /// Response to the speed of the stroke; nil ignores it.
    var velocityDynamics: VelocityDynamics? = nil
    /// How the stroke's colour meets the paint already under it.
    var mixing: PaintMixing = .light
    /// Set for a brush whose strokes dry as a wash on paper; nil for ordinary paint.
    var wet: Wet? = nil
    /// How long the paint stays wet once laid, as a share of the drying time in Settings:
    /// 0 dries at once. While it is wet, a loaded brush crossing it picks it up, and a wash
    /// laid into it blends and feathers instead of glazing over it.
    var wetness: Float = 0
    /// Set for a brush whose strokes lay water that moves; nil for paint that stays put.
    var water: Water? = nil

    /// Paint that flows: a stroke lays water and pigment on the layer, and the water moves
    /// — spreading into dry paper, running downhill with the canvas tilt, pooling in the
    /// paper's valleys — and dries off over the drying time in Settings, leaving the
    /// pigment where it went. Edges darken as the pigment rides out to the receding water;
    /// a wet stroke into a drying wash shoves its pigment outward.
    struct Water: Codable, Equatable {
        /// How much water a stroke lays, 0...1: more spreads further and takes longer to dry.
        var amount: Float = 0.6
        /// How readily the water spreads, 0...1.
        var flow: Float = 0.5
        /// How fast the pigment settles out of the water, 0...1: low leaves it travelling
        /// to the edges, high keeps it where the stroke put it.
        var settling: Float = 0.4
        /// How much more pigment settles in the paper's valleys than on its peaks, 0...1.
        var granulation: Float = 0.5

        init(amount: Float = 0.6, flow: Float = 0.5, settling: Float = 0.4, granulation: Float = 0.5) {
            self.amount = amount
            self.flow = flow
            self.settling = settling
            self.granulation = granulation
        }

        private enum CodingKeys: String, CodingKey { case amount, flow, settling, granulation }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            amount = try c.decodeIfPresent(Float.self, forKey: .amount) ?? 0.6
            flow = try c.decodeIfPresent(Float.self, forKey: .flow) ?? 0.5
            settling = try c.decodeIfPresent(Float.self, forKey: .settling) ?? 0.4
            granulation = try c.decodeIfPresent(Float.self, forKey: .granulation) ?? 0.5
        }
    }

    /// A stroke that dries as a wash: how a watercolour behaves once it is on the paper.
    struct Wet: Codable, Equatable {
        /// How much pigment gathers at the stroke's edge as it dries, 0...1: the soft edge
        /// becomes a crisp boundary with a darker rim inside it, and the middle lightens.
        var edges: Float = 0.6
        /// How much pigment settles into the paper's valleys, 0...1.
        var granulation: Float = 0.5
        /// Paper texels per canvas pixel.
        var grainScale: Float = 1
        /// How much the wash, laid into paint that is still wet, blends with it instead of
        /// glazing over it, 0...1: its colour mixes in as pigment and its edge stays soft
        /// where the paper is wet; over dry paint it glazes with a crisp edge as usual.
        var blendsWhenWet: Float = 1

        init(edges: Float = 0.6, granulation: Float = 0.5, grainScale: Float = 1, blendsWhenWet: Float = 1) {
            self.edges = edges
            self.granulation = granulation
            self.grainScale = grainScale
            self.blendsWhenWet = blendsWhenWet
        }

        private enum CodingKeys: String, CodingKey { case edges, granulation, grainScale, blendsWhenWet }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            edges = try c.decodeIfPresent(Float.self, forKey: .edges) ?? 0.6
            granulation = try c.decodeIfPresent(Float.self, forKey: .granulation) ?? 0.5
            grainScale = try c.decodeIfPresent(Float.self, forKey: .grainScale) ?? 1
            blendsWhenWet = try c.decodeIfPresent(Float.self, forKey: .blendsWhenWet) ?? 1
        }
    }

    enum CodingKeys: String, CodingKey {
        case id, name, category, hardness, baseSize, pressureDynamics, opacity, smoothing, fixedNibAngle
        case rendering, tiltDynamics, velocityDynamics, mixing, wet, wetness, water
    }
}

/// How a stroke's colour meets the paint already on the layer.
enum PaintMixing: String, Codable {
    /// Colours average, as light does on a screen. The usual way.
    case light
    /// Colours mix as pigments do: yellow over blue makes green. See Spectral.h.
    case pigment
    /// A transparent wash that darkens what is under it, like a glaze: never lighter than
    /// the paint beneath.
    case glaze

    /// `StrokeMergeParams.mixing` in Shaders.metal.
    var shaderValue: Int32 {
        switch self {
        case .light: return 0
        case .pigment: return 1
        case .glaze: return 2
        }
    }
}

extension BrushDescriptor {
    /// Files from before `mixing` had a boolean for pigment mixing.
    private enum LegacyKeys: String, CodingKey {
        case mixesPigments
    }

    /// Reads older brush files too, which lack the newer keys.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        category = try c.decode(BrushCategory.self, forKey: .category)
        // A file can say anything; the engine divides by some of these
        hardness = Self.unit(try c.decode(Float.self, forKey: .hardness))
        baseSize = min(max(try c.decode(Float.self, forKey: .baseSize), 1), 2000)
        pressureDynamics = try c.decode(PressureDynamics.self, forKey: .pressureDynamics)
        opacity = Self.unit(try c.decode(Float.self, forKey: .opacity))
        smoothing = Self.unit(try c.decode(Float.self, forKey: .smoothing))
        fixedNibAngle = try c.decodeIfPresent(Float.self, forKey: .fixedNibAngle)
        rendering = (try c.decodeIfPresent(BrushRendering.self, forKey: .rendering) ?? .ribbon(.procedural)).validated
        tiltDynamics = try c.decodeIfPresent(TiltDynamics.self, forKey: .tiltDynamics)
        velocityDynamics = try c.decodeIfPresent(VelocityDynamics.self, forKey: .velocityDynamics)
        if let mixing = try c.decodeIfPresent(PaintMixing.self, forKey: .mixing) {
            self.mixing = mixing
        } else {
            let legacy = try decoder.container(keyedBy: LegacyKeys.self)
            mixing = try legacy.decodeIfPresent(Bool.self, forKey: .mixesPigments) == true ? .pigment : .light
        }
        wet = try c.decodeIfPresent(Wet.self, forKey: .wet)
        wetness = Self.unit(try c.decodeIfPresent(Float.self, forKey: .wetness) ?? 0)
        water = try c.decodeIfPresent(Water.self, forKey: .water)
    }
}

extension BrushDescriptor {
    /// `value` within 0...1; a value that is not a number becomes 0.
    static func unit(_ value: Float) -> Float {
        value.isNaN ? 0 : min(max(value, 0), 1)
    }
}

extension BrushRendering {
    /// Stamp values kept where the dab placer can use them: spacing above zero, flow and
    /// thickness in range.
    var validated: BrushRendering {
        guard case .stamp(var settings) = self else { return self }
        settings.spacing = settings.spacing.isNaN ? 0.01 : max(settings.spacing, 0.01)
        settings.flow = BrushDescriptor.unit(settings.flow)
        if let thickness = settings.impasto?.thickness {
            settings.impasto?.thickness = thickness.isNaN ? 0 : max(thickness, 0)
        }
        return .stamp(settings)
    }
}

extension BrushDescriptor {
    /// The same brush under a different identity. (In an extension so the struct keeps its
    /// memberwise initializer.)
    init(copying other: BrushDescriptor, id: UUID, name: String) {
        self = other
        self.id = id
        self.name = name
    }

    /// Set when the brush moves the paint under it rather than adding its own.
    var smudgeSettings: StampSettings.Smudge? {
        if case .stamp(let settings) = rendering { return settings.smudge }
        return nil
    }
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

/// The cross-section of a ribbon stroke.
enum RibbonShader: String, Codable {
    case procedural   // Hard/soft round via smoothstep

    /// Reads any name, for files that name a shader since retired (the ribbon watercolor,
    /// which the wash settings replaced).
    init(from decoder: Decoder) throws {
        _ = try decoder.singleValueContainer().decode(String.self)
        self = .procedural
    }
}

/// Settings for a brush drawn with dabs.
struct StampSettings: Codable, Equatable {
    /// The shape of one dab.
    enum Tip: Equatable, Hashable {
        /// A disc whose edge softness comes from the brush's `hardness`.
        case round
        /// A rough-edged, blotchy disc, like the end of a stick of chalk.
        case chalk
        /// A disc with a ragged edge, the footprint of a loaded bristle brush. The bristle
        /// streaks themselves come from stroke-attached `bristles` grain.
        case bristle
        /// A blade across the stroke: a thin, wide bar with hard edges, for pushing paint.
        case knife
        /// An image from the brush library's textures folder, by file name. Its alpha
        /// channel is the shape; an image without alpha uses its darkness.
        case image(String)
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
        enum Texture: Equatable, Hashable {
            /// The tooth of cold-press paper.
            case paper
            /// Streaks along the stroke, the marks of individual bristles.
            case bristles
            /// An image from the brush library's textures folder, by file name; its
            /// brightness is the height.
            case image(String)
        }
        enum Attachment: String, Codable {
            /// Fixed to the canvas: every stroke meets the same texture, as with real paper.
            case canvas
            /// Follows the stroke: the texture runs along the path and bends with it, as
            /// bristle marks do.
            case stroke
        }
        var mode: Mode
        var texture: Texture = .paper
        var attachment: Attachment = .canvas
        /// Paper texture pixels per canvas pixel: larger is finer.
        var scale: Float
        /// 0 (no grain) to 1 (strongest). For `height`, the pressure it takes to reach
        /// the paper's deepest valleys.
        var depth: Float
    }

    /// A second tip laid over each dab, masking it: wherever the second tip is clear the
    /// dab is too. Breaks a plain tip up into texture (Photoshop's dual brush, Krita's
    /// masked brush).
    struct SecondTip: Codable, Equatable {
        var tip: Tip
        /// Size relative to the dab; below 1 the second tip tiles across it.
        var scale: Float = 1
        /// Random rotation per dab, as a fraction of a full turn.
        var angleJitter: Float = 0
    }

    /// A brush that moves the paint already on the layer instead of (or as well as) adding
    /// its own. Such a brush draws straight into the layer as the pen moves.
    struct Smudge: Codable, Equatable {
        enum Mode: String, Codable {
            /// Picks up the average colour under the dab and lays it back down: softens
            /// and blends without dragging. Cheap and keeps the tip's shape.
            case dulling
            /// Carries the paint from where the dab was to where it is now: drags and
            /// streaks, like a finger through wet paint.
            case smearing
        }
        var mode: Mode = .smearing
        /// Smearing: how far the paint carries, 0 (not at all) to 1 (for ever); below 1 the
        /// brush runs out over a few diameters. Dulling: how hard each pass blends, 0 to 1.
        /// Either way it reads about the same whatever the spacing.
        var strength: Float = 0.7
        /// How much of the brush's own colour goes in with the carried paint, 0 (pure smudge)
        /// to 1 (plain paint).
        var colorRate: Float = 0

        /// How much of the carried paint one dab lays down, for dabs `spacing` diameters
        /// apart: `strength` is defined at a quarter diameter, and closer dabs each do less so
        /// the stroke does about the same per distance travelled. (Smeared paint runs out
        /// through what the brush leaves behind it, so this is a normalisation, not a law.)
        func depositFraction(spacing: Float) -> Float {
            let quarters = max(spacing, 0.01) * 4
            switch mode {
            case .smearing: return pow(max(strength, 0), quarters)
            case .dulling: return 1 - pow(max(1 - strength, 0), quarters)
            }
        }
    }

    /// A loaded brush: it carries paint, laid down as it goes and run out of, and picks up
    /// what it crosses. The carry is a small texture mapped to the dab, as a smudge's is,
    /// a texel per bristle, so bristles run dry one by one and streak.
    struct Load: Codable, Equatable {
        /// How much paint the brush starts a stroke with, 0...1: the most a dab can lay.
        var amount: Float = 1
        /// The share of the carried paint that leaves per diameter travelled, 0 (never
        /// runs out) to 1.
        var depletion: Float = 0.2
        /// The share of the carry refilled from the brush's own colour per diameter, 0...1:
        /// how fast a dirtied, emptied brush comes back to what it was loaded with.
        var resaturation: Float = 0.05
        /// The share of the paint under the brush that comes up into it per diameter, 0...1:
        /// what it crosses streaks into its tail.
        var bleed: Float = 0.5
        /// How unevenly the bristles are loaded, 0 (evenly) to 1: some run dry long before
        /// the rest.
        var variation: Float = 0.5
    }

    /// Thick paint: every dab adds height to the layer, which the display lights, and
    /// pushes the paint already under it.
    struct Impasto: Codable, Equatable {
        /// Height one dab at full coverage adds. Dabs overlap many times over, so one pass
        /// of a stroke builds roughly `thickness / spacing` times the flow; the display
        /// lights height on a scale where 1 is thick.
        var thickness: Float = 0.08
        /// How much of the paint already under the brush is pushed out to its rim, and
        /// more ahead of it than behind, 0...1: a stroke drives a wave of paint before it
        /// and ends in a ridge, and a second stroke ploughs a furrow through the first. A
        /// knife is all push and no thickness.
        var squeeze: Float = 0.5
        /// Grooves along the stroke from the bristles, 0...1, cut into the height a dab
        /// leaves.
        var grooves: Float = 0.5

        init(thickness: Float = 0.08, squeeze: Float = 0.5, grooves: Float = 0.5) {
            self.thickness = thickness
            self.squeeze = squeeze
            self.grooves = grooves
        }

        private enum CodingKeys: String, CodingKey { case thickness, squeeze, grooves }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            thickness = try c.decodeIfPresent(Float.self, forKey: .thickness) ?? 0.08
            squeeze = try c.decodeIfPresent(Float.self, forKey: .squeeze) ?? 0.5
            grooves = try c.decodeIfPresent(Float.self, forKey: .grooves) ?? 0.5
        }
    }

    var tip: Tip = .round
    var secondTip: SecondTip? = nil
    /// Set for a brush that moves the paint under it.
    var smudge: Smudge? = nil
    /// Set for a brush that lays thick paint.
    var impasto: Impasto? = nil
    /// Set for a brush that carries paint.
    var load: Load? = nil
    /// The tip as a bundle of bristles; nil for a tip that is one shape.
    var bristles: Bristles? = nil

    /// The tip as a bundle: clumps of bristles across the brush that fan out with pressure
    /// and come to a point at a light touch, part at speed so a fast stroke breaks into
    /// streaks, skip the paper's valleys at a light touch (dry-brushing), and each carry
    /// their own share of a loaded brush's paint. The bundle is laid out afresh for every
    /// stroke, and its clumps wander as the stroke goes on; a replay gets the same marks.
    struct Bristles: Codable, Equatable {
        /// Clumps of bristles across the brush.
        var count: Int = 10
        /// How much the bundle narrows at a light touch, 0...1: at 0 it is always its full
        /// width; at 1 a light touch brings the bristles to a point.
        var fan: Float = 0.6
        /// How far the clumps part at speed, 0...1.
        var parting: Float = 0.5
        /// How much a light touch skips the paper's valleys, 0...1.
        var dryBrush: Float = 0.5

        init(count: Int = 10, fan: Float = 0.6, parting: Float = 0.5, dryBrush: Float = 0.5) {
            self.count = count
            self.fan = fan
            self.parting = parting
            self.dryBrush = dryBrush
        }

        private enum CodingKeys: String, CodingKey { case count, fan, parting, dryBrush }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            count = min(max(try c.decodeIfPresent(Int.self, forKey: .count) ?? 10, 1), 32)
            fan = try c.decodeIfPresent(Float.self, forKey: .fan) ?? 0.6
            parting = try c.decodeIfPresent(Float.self, forKey: .parting) ?? 0.5
            dryBrush = try c.decodeIfPresent(Float.self, forKey: .dryBrush) ?? 0.5
        }
    }
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
    /// Dabs per second laid where the pen rests without moving. 0 means a resting pen adds
    /// nothing, as a pencil wouldn't; an airbrush keeps spraying.
    var holdRate: Float = 0
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
        )),
        // Lean the pencil over to shade with its side: a broad, pale, elongated mark
        tiltDynamics: TiltDynamics(sizeScale: 2.5, opacityScale: 0.55, aspect: 2.0)
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
        fixedNibAngle: nil,
        // A loaded brush thins as it is swept faster
        velocityDynamics: VelocityDynamics(referenceSpeed: 1500, sizeScale: 0.55, opacityScale: 1.0)
    )

    static let marker = BrushDescriptor(
        id: UUID(uuidString: "00000000-0005-0000-0000-000000000005")!,
        name: "Marker",
        category: .painting,
        hardness: 0.6,
        baseSize: 32,
        pressureDynamics: PressureDynamics(
            sizeRange: 0.85...1.0,
            opacityRange: 0.8...1.0
        ),
        opacity: 0.7,          // translucent: each separate stroke darkens the last
        smoothing: 0.3,
        fixedNibAngle: nil,
        // A wash, so going back over a stroke without lifting stays flat; faint streaks
        // run along the stroke the way a felt tip leaves them.
        rendering: .stamp(StampSettings(
            spacing: 0.08, flow: 0.85, accumulation: .wash,
            grain: .init(mode: .multiply, texture: .bristles, attachment: .stroke, scale: 1.6, depth: 0.2),
            followsDirection: true
        ))
    )

    static let watercolor = BrushDescriptor(
        id: UUID(uuidString: "00000000-0007-0000-0000-000000000007")!,
        name: "Watercolor",
        category: .painting,
        hardness: 0.3,
        baseSize: 40,
        pressureDynamics: PressureDynamics(
            sizeRange: 0.4...1.0,
            opacityRange: 0.6...0.9
        ),
        opacity: 0.65,
        smoothing: 0.4,
        fixedNibAngle: nil,
        // A wash: dabs build to the stroke's opacity, and the stroke dries with crisp edges
        // where the pigment gathers, settles into the paper, and glazes what is under it
        rendering: .stamp(StampSettings(spacing: 0.1, flow: 0.35, accumulation: .wash)),
        // Fast strokes are drier
        velocityDynamics: VelocityDynamics(referenceSpeed: 1500, sizeScale: 0.85, opacityScale: 0.6),
        mixing: .glaze,
        // Stays wet the whole drying time: a second wash into it blends and feathers
        wetness: 1,
        // The wash is water that moves: it spreads, dries from the edges in, and leaves the
        // pigment where the water took it, so the edges darken and the grain shows
        water: Water(amount: 0.6, flow: 0.5, settling: 0.4, granulation: 0.5)
    )

    /// Clean water: lays no colour, only water, so a wash can be started into wet paper,
    /// softened, or pushed about after it is down.
    static let water = BrushDescriptor(
        id: UUID(uuidString: "00000000-0017-0000-0000-000000000017")!,
        name: "Water",
        category: .painting,
        hardness: 0.3,
        baseSize: 40,
        pressureDynamics: PressureDynamics(
            sizeRange: 0.5...1.0,
            opacityRange: 1.0...1.0
        ),
        opacity: 0,
        smoothing: 0.4,
        fixedNibAngle: nil,
        rendering: .stamp(StampSettings(spacing: 0.1, flow: 0.5, accumulation: .wash)),
        mixing: .glaze,
        wetness: 1,
        water: Water(amount: 1, flow: 0.6, settling: 0.4, granulation: 0.5)
    )

    static let acrylic = BrushDescriptor(
        id: UUID(uuidString: "00000000-0008-0000-0000-000000000008")!,
        name: "Acrylic",
        category: .painting,
        hardness: 0.75,
        baseSize: 28,
        pressureDynamics: PressureDynamics(
            sizeRange: 0.5...1.0,
            opacityRange: 0.6...1.0   // Heavy coverage
        ),
        opacity: 0.95,
        smoothing: 0.3,
        fixedNibAngle: nil,
        rendering: .stamp(StampSettings(
            tip: .bristle,
            impasto: .init(thickness: 0.075, squeeze: 0.35, grooves: 0.3),
            // Loaded: dries faster than oil and takes up less of what it crosses
            load: .init(amount: 1, depletion: 0.25, resaturation: 0.1, bleed: 0.4, variation: 0.5),
            bristles: .init(count: 10, fan: 0.5, parting: 0.6, dryBrush: 0.5),
            spacing: 0.05, flow: 0.6, accumulation: .wash,
            grain: .init(mode: .multiply, texture: .bristles, attachment: .stroke, scale: 1.2, depth: 0.3),
            opacityJitter: 0.1, followsDirection: true
        )),
        mixing: .pigment,
        // Dries fast: wet for well under half the drying time
        wetness: 0.4
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
        )),
        tiltDynamics: TiltDynamics(sizeScale: 2.0, opacityScale: 0.6, aspect: 1.8)
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
        )),
        tiltDynamics: TiltDynamics(sizeScale: 1.8, opacityScale: 0.7, aspect: 1.6)
    )

    static let oil = BrushDescriptor(
        id: UUID(uuidString: "00000000-0014-0000-0000-000000000014")!,
        name: "Oil",
        category: .painting,
        hardness: 0.8,
        baseSize: 30,
        pressureDynamics: PressureDynamics(
            sizeRange: 0.45...1.0,
            opacityRange: 0.7...1.0   // rich, heavy coverage
        ),
        opacity: 0.95,
        smoothing: 0.3,
        fixedNibAngle: nil,
        // Thicker paint than acrylic: deeper bristle furrows
        rendering: .stamp(StampSettings(
            tip: .bristle,
            // Thickness follows the paint on the brush, so a little more of it than before;
            // pushes what it presses into, and leaves grooves
            impasto: .init(thickness: 0.1, squeeze: 0.5, grooves: 0.4),
            // Loaded: runs out slowly, drags what it crosses, comes back to its colour slowly
            load: .init(amount: 1, depletion: 0.12, resaturation: 0.06, bleed: 0.5, variation: 0.6),
            // A bundle of a dozen clumps: narrows at a light touch, breaks into streaks at
            // speed, and scumbles over the tooth when barely pressed
            bristles: .init(count: 12, fan: 0.6, parting: 0.5, dryBrush: 0.4),
            spacing: 0.05, flow: 0.75, accumulation: .wash,
            grain: .init(mode: .multiply, texture: .bristles, attachment: .stroke, scale: 1.0, depth: 0.35),
            sizeJitter: 0.05, opacityJitter: 0.1, followsDirection: true
        )),
        mixing: .pigment,
        // Stays wet the whole drying time: a brush crossing it picks it up until then
        wetness: 1
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
        // Faint dabs with no cap: paint keeps building as you go back over it, or as you
        // hold the pen in one place.
        rendering: .stamp(StampSettings(spacing: 0.06, flow: 0.07, accumulation: .buildUp, holdRate: 60))
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
        )),
        tiltDynamics: TiltDynamics(sizeScale: 1.6, opacityScale: 0.75, aspect: 1.5)
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
        )),
        tiltDynamics: TiltDynamics(sizeScale: 1.5, opacityScale: 0.8, aspect: 1.4)
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
        fixedNibAngle: nil,
        velocityDynamics: VelocityDynamics(referenceSpeed: 1200, sizeScale: 0.45, opacityScale: 0.75)
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

    static let smudge = BrushDescriptor(
        id: UUID(uuidString: "00000000-0015-0000-0000-000000000015")!,
        name: "Smudge",
        category: .painting,
        hardness: 0.3,
        baseSize: 36,
        pressureDynamics: PressureDynamics(
            sizeRange: 0.6...1.0,
            opacityRange: 0.4...1.0    // press harder to carry more paint
        ),
        opacity: 1.0,
        smoothing: 0.4,
        fixedNibAngle: nil,
        // Drags the paint under it; adds none of its own
        rendering: .stamp(StampSettings(
            smudge: .init(mode: .smearing, strength: 0.75, colorRate: 0),
            spacing: 0.08, flow: 1.0, accumulation: .buildUp
        )),
        mixing: .pigment
    )

    static let paletteKnife = BrushDescriptor(
        id: UUID(uuidString: "00000000-0016-0000-0000-000000000016")!,
        name: "Palette Knife",
        category: .painting,
        hardness: 1.0,
        baseSize: 40,
        pressureDynamics: PressureDynamics(
            sizeRange: 1.0...1.0,
            opacityRange: 0.5...1.0    // press harder to push more
        ),
        opacity: 1.0,
        smoothing: 0.3,
        fixedNibAngle: nil,
        // Lays nothing: drags the paint under it along, and pushes what it presses into
        // out to the blade's edges and ahead of it
        rendering: .stamp(StampSettings(
            tip: .knife,
            smudge: .init(mode: .smearing, strength: 0.85, colorRate: 0),
            impasto: .init(thickness: 0, squeeze: 0.9, grooves: 0),
            spacing: 0.04, flow: 1.0, accumulation: .buildUp,
            followsDirection: true
        )),
        mixing: .pigment
    )

    static let allDefaults: [BrushDescriptor] = [
        // Sketching
        .pencil, .graphiteStick, .conte, .chalk, .pastel,
        // Inking
        .hardRound, .inkBrush, .sumiE, .calligraphy,
        .technicalPen, .fineliner, .ballpointPen, .gelPen,
        // Painting
        .softRound, .airbrush, .marker, .watercolor, .water, .acrylic, .oil, .smudge, .paletteKnife
    ]

    /// Look up a built-in brush (including the eraser) by its display name.
    static func builtIn(named name: String) -> BrushDescriptor? {
        (allDefaults + [eraser]).first { $0.name == name }
    }
}

// MARK: - Tips and textures as strings

/// Tips and grain textures are written as plain strings in brush files: the built-in
/// ones by name, images as "image:<file name>".
extension StampSettings.Tip: Codable {
    init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        switch raw {
        case "round": self = .round
        case "chalk": self = .chalk
        case "bristle": self = .bristle
        case "knife": self = .knife
        case _ where raw.hasPrefix("image:"): self = .image(String(raw.dropFirst("image:".count)))
        default:
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "Unknown tip \"\(raw)\""))
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .round: try container.encode("round")
        case .chalk: try container.encode("chalk")
        case .bristle: try container.encode("bristle")
        case .knife: try container.encode("knife")
        case .image(let name): try container.encode("image:" + name)
        }
    }
}

extension StampSettings.Grain.Texture: Codable {
    init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        switch raw {
        case "paper": self = .paper
        case "bristles": self = .bristles
        case _ where raw.hasPrefix("image:"): self = .image(String(raw.dropFirst("image:".count)))
        default:
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "Unknown texture \"\(raw)\""))
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .paper: try container.encode("paper")
        case .bristles: try container.encode("bristles")
        case .image(let name): try container.encode("image:" + name)
        }
    }
}
