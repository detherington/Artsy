import Foundation

/// One copy of a brush tip.
struct Dab {
    var center: CGPoint
    /// Diameter in canvas pixels.
    var size: Float
    /// Rotation in radians.
    var angle: Float
    /// Length-to-width ratio (1 = round).
    var aspect: Float = 1
    var opacity: Float
    /// 0..<1, different for every dab; the shader uses it to vary the tip.
    var seed: Float
    /// 0...1: how firmly the dab is pressed into the paper. Only matters to height grain,
    /// where it decides how far into the paper's valleys the pigment gets.
    var reach: Float = 1
}

/// Walks a stroke's path and lays dabs along it at the brush's spacing.
///
/// It is a value type on purpose. The renderer keeps one placer for the settled part of the
/// stroke and advances it for good; for the unsettled tail it advances a throwaway copy every
/// frame. Because a dab's jitter comes from its index, a tail dab looks the same once the
/// path under it settles and the real placer reaches it.
struct DabPlacer {
    /// Path distance at which the next dab goes down.
    private var nextDistance: CGFloat = 0
    private var index = 0
    /// Where in the point array to resume searching.
    private var cursor = 0
    private let strokeSeed: UInt64

    /// - Parameter strokeSeed: varies the jitter from stroke to stroke. Derive it from the
    ///   stroke itself so a replay gets the same dabs.
    init(strokeSeed: UInt64) {
        self.strokeSeed = strokeSeed
    }

    /// The dabs between where this placer has got to and path distance `limit`.
    mutating func dabs(along points: [InterpolatedPoint], upTo limit: CGFloat,
                       brush: BrushDescriptor, settings: StampSettings) -> [Dab] {
        guard !points.isEmpty else { return [] }
        var result: [Dab] = []

        // A tap has no length to lay overlapping dabs along, and one dab of a low-flow brush
        // is nearly invisible. Put down as many as cover any one spot in the middle of a
        // stroke, so a tap leaves a dot as dense as the stroke would be.
        let isTap = points[points.count - 1].distance <= 0
        let copies = isTap ? max(1, Int((0.5 / settings.spacing).rounded())) : 1

        while nextDistance <= limit {
            // The segment of the path that contains nextDistance
            while cursor + 1 < points.count, points[cursor + 1].distance < nextDistance { cursor += 1 }
            let a = points[cursor]
            let b = points[min(cursor + 1, points.count - 1)]
            let span = b.distance - a.distance
            let t = span > 0 ? Float(min(1, max(0, (nextDistance - a.distance) / span))) : 0

            let width = a.width + (b.width - a.width) * t
            var size = width
            let aspect = a.aspect + (b.aspect - a.aspect) * t
            // Pressure normally thins each dab. With height grain it instead decides how
            // deep into the paper the dab reaches, which lightens the mark by itself.
            let pressed = a.opacity + (b.opacity - a.opacity) * t
            let usesReach = settings.grain?.mode == .height
            var opacity = usesReach ? settings.flow : pressed * settings.flow
            var center = CGPoint(x: a.position.x + (b.position.x - a.position.x) * CGFloat(t),
                                 y: a.position.y + (b.position.y - a.position.y) * CGFloat(t))
            // Interpolating an angle across the ±π seam would spin the dab; the path is
            // sampled every pixel, so the nearer point's direction is close enough.
            let nearer = t < 0.5 ? a : b
            let direction = nearer.angle
            var angle = settings.followsDirection ? direction : 0
            // A mark elongated by tilt lies along the lean; barrel rotation turns any tip.
            if aspect > 1.001 { angle = nearer.tiltAngle }
            angle += nearer.rotation

            if settings.sizeJitter > 0 {
                size *= 1 - settings.sizeJitter * random(1)
            }
            if settings.opacityJitter > 0 {
                opacity *= 1 - settings.opacityJitter * random(2)
            }
            if settings.angleJitter > 0 {
                angle += (random(3) - 0.5) * 2 * .pi * settings.angleJitter
            }
            if settings.scatter > 0 {
                // Mostly across the stroke, a little along it
                let across = CGFloat((random(4) - 0.5) * 2 * settings.scatter * width)
                let along = CGFloat((random(5) - 0.5) * settings.scatter * width)
                let dx = CGFloat(cos(direction)), dy = CGFloat(sin(direction))
                center.x += -dy * across + dx * along
                center.y += dx * across + dy * along
            }

            result.append(Dab(center: center, size: max(size, 0.5), angle: angle, aspect: aspect,
                              opacity: opacity, seed: random(0), reach: usesReach ? pressed : 1))
            index += 1

            // Each copy of a tap's dab gets its own index, and so its own jitter.
            if isTap, index < copies { continue }

            // Spacing follows the brush's width here, not the jittered dab, so jitter
            // doesn't bunch dabs up. Never less than a fraction of a pixel.
            nextDistance += CGFloat(max(settings.spacing * width, 0.35))
        }
        return result
    }

    /// A repeatable random number in 0..<1 for the current dab; `channel` picks which one.
    private func random(_ channel: UInt64) -> Float {
        // SplitMix64 over (stroke, dab, channel)
        var z = strokeSeed &+ UInt64(index) &* 0x9E3779B97F4A7C15 &+ channel &* 0xD1B54A32D192ED03
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        z ^= z >> 31
        return Float(z >> 40) / Float(1 << 24)
    }
}
