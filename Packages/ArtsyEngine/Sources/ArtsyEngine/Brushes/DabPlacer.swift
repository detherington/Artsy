import Foundation

/// One copy of a brush tip.
public struct Dab {
    public var center: CGPoint
    /// Diameter in canvas pixels.
    public var size: Float
    /// Rotation in radians.
    public var angle: Float
    /// Length-to-width ratio (1 = round).
    public var aspect: Float = 1
    public var opacity: Float
    /// 0..<1, different for every dab; the shader uses it to vary the tip.
    public var seed: Float
    /// 0...1: how firmly the dab is pressed into the paper. Only matters to height grain,
    /// where it decides how far into the paper's valleys the pigment gets.
    public var reach: Float = 1
    /// How far along the stroke the dab sits; stroke-attached grain runs along it.
    public var pathDistance: Float = 0
    /// Rotation of the second tip, radians.
    public var secondAngle: Float = 0
    /// Which way the stroke was going at this dab, radians: thick paint is pushed ahead.
    public var heading: Float = 0
    /// How wide a bristle bundle is here, 0...1 of its full width: narrower at a light touch.
    public var fan: Float = 1
    /// How far the bundle's clumps have parted here, 0...1: further at speed.
    public var gap: Float = 0
    /// The stroke's seed, 0...65535: the shaders lay the bristles and the streaks out by it,
    /// so no two strokes share a layout and a replay gets the same one.
    public var strokeSeed: Float = 0

    public init(center: CGPoint, size: Float, angle: Float, aspect: Float = 1, opacity: Float, seed: Float, reach: Float = 1, pathDistance: Float = 0, secondAngle: Float = 0, heading: Float = 0, fan: Float = 1, gap: Float = 0, strokeSeed: Float = 0) {
        self.center = center
        self.size = size
        self.angle = angle
        self.aspect = aspect
        self.opacity = opacity
        self.seed = seed
        self.reach = reach
        self.pathDistance = pathDistance
        self.secondAngle = secondAngle
        self.heading = heading
        self.fan = fan
        self.gap = gap
        self.strokeSeed = strokeSeed
    }
}

/// Walks a stroke's path and lays dabs along it at the brush's spacing.
///
/// It is a value type on purpose. The renderer keeps one placer for the settled part of the
/// stroke and advances it for good; for the unsettled tail it advances a throwaway copy every
/// frame. Because a dab's jitter comes from its index, a tail dab looks the same once the
/// path under it settles and the real placer reaches it.
public struct DabPlacer {
    /// The speed, canvas pixels a second, at which a bundle's clumps have fully parted.
    public static let partingSpeed: Float = 1500
    /// Path distance at which the next dab goes down.
    private var nextDistance: CGFloat = 0
    private var index = 0
    /// Where in the point array to resume searching.
    private var cursor = 0
    private let strokeSeed: UInt64
    /// How far a bristle bundle is splayed: up with the pressure at once, down slowly.
    private var splay: Float = 0
    private var splayDistance: CGFloat = 0

    /// - Parameter strokeSeed: varies the jitter from stroke to stroke. Derive it from the
    ///   stroke itself so a replay gets the same dabs.
    public init(strokeSeed: UInt64) {
        self.strokeSeed = strokeSeed
    }

    /// The dabs between where this placer has got to and path distance `limit`.
    public mutating func dabs(along points: [InterpolatedPoint], upTo limit: CGFloat,
                       brush: BrushDescriptor, settings: StampSettings) -> [Dab] {
        guard !points.isEmpty else { return [] }
        var result: [Dab] = []

        // A tap has no length to lay overlapping dabs along, and one dab of a low-flow brush
        // is nearly invisible. Put down as many as cover any one spot in the middle of a
        // stroke, so a tap leaves a dot as dense as the stroke would be.
        let isTap = points[points.count - 1].distance <= 0
        let copies = isTap ? max(1, Int((0.5 / max(settings.spacing, 0.01)).rounded())) : 1

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
            // A bundle of bristles: narrower the lighter the touch, parted the faster the pen.
            // Pressed hard it splays, and holds the splay for about a diameter after the
            // touch eases, as bristles do: the fan follows the pressure up at once, down slowly.
            let press = a.pressure + (b.pressure - a.pressure) * t
            let speed = a.speed + (b.speed - a.speed) * t
            splay = max(press, splay * exp(-Float(nextDistance - splayDistance) / max(width, 1)))
            splayDistance = nextDistance
            let fan = settings.bristles.map { 1 - $0.fan * (1 - splay) } ?? 1
            let gap = settings.bristles.map { $0.parting * min(1, speed / Self.partingSpeed) } ?? 0
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

            let secondAngle = (settings.secondTip?.angleJitter ?? 0) > 0
                ? (random(6) - 0.5) * 2 * .pi * settings.secondTip!.angleJitter : 0
            result.append(Dab(center: center, size: max(size, 0.5), angle: angle, aspect: aspect,
                              opacity: opacity, seed: random(0),
                              // How firmly the dab is pressed: the paper's tooth, and dry-brushing
                              reach: usesReach ? pressed : (settings.bristles != nil ? press : 1),
                              pathDistance: Float(nextDistance), secondAngle: secondAngle, heading: direction,
                              fan: fan, gap: gap, strokeSeed: Float(strokeSeed & 0xFFFF)))
            index += 1

            // Each copy of a tap's dab gets its own index, and so its own jitter.
            if isTap, index < copies { continue }

            // Spacing follows the brush's width here, not the jittered dab, so jitter
            // doesn't bunch dabs up. Never less than a fraction of a pixel.
            nextDistance += CGFloat(max(settings.spacing * width, 0.35))
        }
        return result
    }

    /// Dabs for a pen resting at `point`, for brushes that keep spraying while held still.
    /// Each gets its own jitter; they do not advance the placer along the path.
    public mutating func restingDabs(at point: InterpolatedPoint, count: Int, settings: StampSettings) -> [Dab] {
        guard count > 0 else { return [] }
        let usesReach = settings.grain?.mode == .height
        return (0..<count).map { _ in
            defer { restingIndex += 1 }
            var size = point.width
            var opacity = usesReach ? settings.flow : point.opacity * settings.flow
            var center = point.position
            var angle = settings.followsDirection ? point.angle : 0
            if point.aspect > 1.001 { angle = point.tiltAngle }
            angle += point.rotation
            if settings.sizeJitter > 0 { size *= 1 - settings.sizeJitter * restingRandom(1) }
            if settings.opacityJitter > 0 { opacity *= 1 - settings.opacityJitter * restingRandom(2) }
            if settings.angleJitter > 0 { angle += (restingRandom(3) - 0.5) * 2 * .pi * settings.angleJitter }
            if settings.scatter > 0 {
                center.x += CGFloat((restingRandom(4) - 0.5) * 2 * settings.scatter * point.width)
                center.y += CGFloat((restingRandom(5) - 0.5) * 2 * settings.scatter * point.width)
            }
            let secondAngle = (settings.secondTip?.angleJitter ?? 0) > 0
                ? (restingRandom(6) - 0.5) * 2 * .pi * settings.secondTip!.angleJitter : 0
            return Dab(center: center, size: max(size, 0.5), angle: angle, aspect: point.aspect,
                       opacity: opacity, seed: restingRandom(0),
                       reach: usesReach ? point.opacity : (settings.bristles != nil ? point.pressure : 1),
                       pathDistance: Float(point.distance), secondAngle: secondAngle, heading: point.angle,
                       fan: settings.bristles.map { 1 - $0.fan * (1 - point.pressure) } ?? 1, gap: 0,
                       strokeSeed: Float(strokeSeed & 0xFFFF))
        }
    }

    /// Resting dabs count separately from dabs along the path, so laying them does not
    /// change the jitter of the dabs that follow.
    private var restingIndex = 0

    private func restingRandom(_ channel: UInt64) -> Float {
        hash(strokeSeed ^ 0x5EED0FA112B5, index: restingIndex, channel: channel)
    }

    /// A repeatable random number in 0..<1 for the current dab; `channel` picks which one.
    private func random(_ channel: UInt64) -> Float {
        hash(strokeSeed, index: index, channel: channel)
    }

    private func hash(_ seed: UInt64, index: Int, channel: UInt64) -> Float {
        // SplitMix64 over (seed, dab, channel)
        var z = seed &+ UInt64(index) &* 0x9E3779B97F4A7C15 &+ channel &* 0xD1B54A32D192ED03
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        z ^= z >> 31
        return Float(z >> 40) / Float(1 << 24)
    }
}
