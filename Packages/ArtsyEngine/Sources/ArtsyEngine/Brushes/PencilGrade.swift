import Foundation

/// A graphite pencil's grade, 4H to 8B: a softness from 0 to 1, and the named points a
/// sketcher reaches for. A hard pencil holds a fine, crisp point, never gets past mid-grey
/// however hard it is pressed, and marks only the paper's peaks; a soft one goes dark at a
/// light touch, broadens under pressure, fills the valleys and crumbles. The grade is a live
/// control on a graphite brush (`BrushDescriptor.graphite`), like its size, remembered per
/// brush; the brush's own values are its HB.
public enum PencilGrade: String, Codable, CaseIterable, Identifiable {
    case h4 = "4H", h2 = "2H", h = "H", hb = "HB", b = "B", b2 = "2B", b4 = "4B", b6 = "6B", b8 = "8B"

    public var id: String { rawValue }

    /// The grades the brush panel offers.
    public static let shown: [PencilGrade] = [.h2, .h, .hb, .b, .b2, .b4, .b6]

    /// 0 at 4H, 1 at 8B; HB is 0.35.
    public var softness: Float {
        switch self {
        case .h4: return 0
        case .h2: return 0.15
        case .h: return 0.25
        case .hb: return 0.35
        case .b: return 0.45
        case .b2: return 0.55
        case .b4: return 0.75
        case .b6: return 0.9
        case .b8: return 1
        }
    }

    public var help: String {
        switch self {
        case .h4, .h2, .h: return "Hard: a fine, light line that stays on the paper's peaks"
        case .hb: return "The brush as it is"
        case .b, .b2: return "Soft: darker, and darker still with pressure"
        case .b4, .b6, .b8: return "Very soft: dark at a touch, broad under pressure, crumbly"
        }
    }
}

public extension BrushDescriptor {
    /// This brush at `grade`: itself at HB, harder or softer from there. A brush that is
    /// not graphite is itself at any grade.
    public func graded(_ grade: PencilGrade) -> BrushDescriptor {
        guard graphite, grade != .hb else { return self }
        let s = grade.softness
        // Each knob against softness, through the named points, flat beyond the ends
        func curve(_ points: [(Float, Float)]) -> Float {
            if s <= points[0].0 { return points[0].1 }
            for (a, b) in zip(points, points.dropFirst()) where s <= b.0 {
                return a.1 + (b.1 - a.1) * (s - a.0) / (b.0 - a.0)
            }
            return points[points.count - 1].1
        }
        // For a height-grain brush the pressure's opacity is also how far into the paper a
        // dab reaches, so a hard lead keeps that near HB (it digs in as well as any) and
        // sheds less graphite instead; a soft one reaches further and sheds more
        let cap = curve([(0.15, 0.9), (0.35, 1.0), (0.55, 1.05), (0.9, 1.15)])     // how far pressed fully reaches
        let light = curve([(0.15, 0.7), (0.35, 1.0), (0.55, 1.3), (0.9, 1.6)])     // how far a light touch reaches
        let deposit = curve([(0.15, 0.4), (0.35, 1.0), (0.55, 1.15), (0.9, 1.4)])  // graphite shed per dab
        let reach = curve([(0.15, 1.0), (0.35, 1.0), (0.55, 0.85), (0.9, 0.7)])    // the pressure the valleys take
        let width = curve([(0.15, 0.75), (0.35, 1.0), (0.55, 1.2), (0.9, 1.5)])    // the point
        let edge = curve([(0.15, 0.15), (0.35, 0), (0.55, -0.1), (0.9, -0.2)])     // crisper or softer
        let crumble = curve([(0.15, 0.6), (0.35, 1.0), (0.55, 1.3), (0.9, 1.8)])   // unevenness of the deposit

        var brush = self
        let dynamics = pressureDynamics
        let darkest = min(dynamics.opacityMax * cap, 1)
        brush.pressureDynamics = PressureDynamics(
            sizeRange: (dynamics.sizeMin * width)...(dynamics.sizeMax * width),
            opacityRange: min(dynamics.opacityMin * light, darkest)...darkest
        )
        brush.hardness = min(max(hardness + edge, 0), 1)
        if case .stamp(var settings) = rendering {
            settings.flow = min(settings.flow * deposit, 1)
            settings.opacityJitter = min(settings.opacityJitter * crumble, 1)
            if var grain = settings.grain {
                grain.depth = min(max(grain.depth * reach, 0.05), 1)
                settings.grain = grain
            }
            brush.rendering = .stamp(settings)
        }
        return brush
    }
}
