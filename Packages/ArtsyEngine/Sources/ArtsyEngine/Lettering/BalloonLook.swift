import CoreGraphics
import Foundation

/// A balloon's outline within its kind: each kind offers its own few (`BalloonStyle.shapes`),
/// the first its usual one.
public enum BalloonShape: String, Codable, CaseIterable, Identifiable {
    /// Speech: an oval, a box with round corners, a box, an oval drawn by hand.
    case oval, rounded, box, wobbly
    /// Thought: the uneven cloud, or one of fewer, rounder puffs.
    case cloud, puffy
    /// Shout: the regular burst, a rough edge for anger, uneven spikes for an explosion.
    case burst, jagged, blast
    /// Caption: leaning sides, or the corners cut off.
    case slanted, notched

    public var id: String { rawValue }
}

/// How a balloon's outline is inked: a whisper's dashes, a radio's zigzag, or none at all.
public enum BalloonLine: String, Codable, CaseIterable, Identifiable {
    case solid, heavy, dashed, double, wavy, electric, none

    public var id: String { rawValue }
    /// Whether it moves the outline itself, not only how the outline is stroked.
    var reshapes: Bool { self == .wavy || self == .electric }
}

/// What a balloon is filled with. The words are black, or white in a black balloon.
public enum BalloonFill: String, Codable, CaseIterable, Identifiable {
    case white, cream, yellow, blue, pink, black

    public var id: String { rawValue }
    public var color: CGColor {
        switch self {
        case .white: return CGColor(gray: 1, alpha: 1)
        case .cream: return CGColor(srgbRed: 1, green: 0.965, blue: 0.85, alpha: 1)
        case .yellow: return CGColor(srgbRed: 1, green: 0.894, blue: 0.4, alpha: 1)
        case .blue: return CGColor(srgbRed: 0.8, green: 0.894, blue: 1, alpha: 1)
        case .pink: return CGColor(srgbRed: 1, green: 0.83, blue: 0.87, alpha: 1)
        case .black: return CGColor(gray: 0, alpha: 1)
        }
    }
    /// The words' colour on it.
    public var wordsColor: CGColor { CGColor(gray: self == .black ? 1 : 0, alpha: 1) }
    /// The colour between a double line's two strokes: the fill, or white in a black balloon.
    var gapColor: CGColor { self == .black ? CGColor(gray: 1, alpha: 1) : color }
}

/// A tail's shape: a wedge, curved or straight; bubbles trailing off, as a thought's do; or
/// a zigzag of lightning, for a voice from a speaker.
public enum BalloonTail: String, Codable, CaseIterable, Identifiable {
    case curved, straight, bubbles, lightning

    public var id: String { rawValue }
}

/// How a balloon looks past its kind: its shape, its line, its fill, and its tail's shape
/// and width. The plain look is every balloon's from before there were looks.
public struct BalloonLook: Codable, Hashable {
    /// The shape; nil, or one the kind does not offer, for the kind's own.
    public var shape: BalloonShape?
    public var line: BalloonLine
    public var fill: BalloonFill
    /// The tail's shape; nil for the kind's own.
    public var tail: BalloonTail?
    /// How wide the tail is, as a share of its usual width: its root's breadth, a lightning
    /// band's, the bubbles' size.
    public var tailWidth: CGFloat

    /// The narrowest and widest a tail is made.
    public static let tailWidths: ClosedRange<CGFloat> = 0.3...3

    public init(shape: BalloonShape? = nil, line: BalloonLine = .solid, fill: BalloonFill = .white, tail: BalloonTail? = nil,
                tailWidth: CGFloat = 1) {
        self.shape = shape
        self.line = line
        self.fill = fill
        self.tail = tail
        self.tailWidth = tailWidth
    }
}

extension BalloonStyle {
    /// The shapes a balloon of this kind can take, its usual one first; none for a sound
    /// effect, which has no body.
    public var shapes: [BalloonShape] {
        switch self {
        case .speech: return [.oval, .rounded, .box, .wobbly]
        case .thought: return [.cloud, .puffy, .oval]
        case .shout: return [.burst, .jagged, .blast]
        case .caption: return [.box, .rounded, .slanted, .notched]
        case .sound: return []
        }
    }

    /// The tail a balloon of this kind has unless another is chosen.
    public var ownTail: BalloonTail {
        switch self {
        case .thought: return .bubbles
        case .shout: return .straight
        default: return .curved
        }
    }
}

extension Balloon {
    /// The shape it is drawn in: its look's, where its kind offers it, else its kind's own;
    /// nil for a sound effect.
    public var shape: BalloonShape? {
        if let shape = look.shape, style.shapes.contains(shape) { return shape }
        return style.shapes.first
    }

    /// Its tail's shape: its look's, else its kind's own.
    public var tailShape: BalloonTail { look.tail ?? style.ownTail }
}

/// The shapes' geometry, for `BalloonLayout`: canvas pixels, y up.
enum BalloonGeometry {
    /// An ellipse: a body's own, or the one inside a box that a tail grows from.
    typealias Ellipse = (center: CGPoint, a: CGFloat, b: CGFloat)

    static func perimeter(of e: Ellipse) -> CGFloat {
        let (a, b) = (e.a, e.b)
        return CGFloat.pi * (3 * (a + b) - ((3 * a + b) * (a + 3 * b)).squareRoot())
    }

    static func point(on e: Ellipse, at angle: CGFloat, reach: CGFloat = 1) -> CGPoint {
        CGPoint(x: e.center.x + e.a * reach * cos(angle), y: e.center.y + e.b * reach * sin(angle))
    }

    /// The box a boxed balloon's words sit in: a caption's as tight as it ever was, a
    /// speech balloon's with more room, as a letterer leaves inside a border.
    static func box(of style: BalloonStyle, around words: CGRect, pad: CGFloat) -> CGRect {
        style == .caption ? words.insetBy(dx: -pad, dy: -pad * 0.8) : words.insetBy(dx: -pad * 1.4, dy: -pad * 1.1)
    }

    /// A box with round corners round `words`: a speech balloon's nearly a lozenge, a
    /// caption's only eased. The margins grow with the corners, so the words' corners stay
    /// `clear` inside the curve, as a wavy line pulls it in.
    static func rounded(around words: CGRect, style: BalloonStyle, pad: CGFloat, size: CGFloat, clear: CGFloat) -> CGPath {
        let plain = box(of: style, around: words, pad: pad)
        let radius = style == .caption ? min(size * 0.6, plain.height * 0.3) : min(plain.width, plain.height) * 0.42
        // A corner's curve comes in three tenths of its radius along the diagonal
        let dx = max(words.minX - plain.minX, radius * 0.3 + clear)
        let dy = max(words.minY - plain.minY, radius * 0.3 + clear)
        let rect = words.insetBy(dx: -dx, dy: -dy)
        return CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil)
    }

    /// A box whose sides lean right, wider at the foot and the head so the words still clear.
    static func slanted(_ rect: CGRect) -> CGPath {
        let lean = rect.height * 0.22
        let path = CGMutablePath()
        path.addLines(between: [CGPoint(x: rect.minX - lean, y: rect.minY), CGPoint(x: rect.maxX, y: rect.minY),
                                CGPoint(x: rect.maxX + lean, y: rect.maxY), CGPoint(x: rect.minX, y: rect.maxY)])
        path.closeSubpath()
        return path
    }

    /// A box with its corners cut off square.
    static func notched(_ rect: CGRect, size: CGFloat) -> CGPath {
        let cut = min(size * 0.6, rect.height * 0.28, rect.width * 0.2)
        let path = CGMutablePath()
        path.addLines(between: [CGPoint(x: rect.minX + cut, y: rect.minY), CGPoint(x: rect.maxX - cut, y: rect.minY),
                                CGPoint(x: rect.maxX, y: rect.minY + cut), CGPoint(x: rect.maxX, y: rect.maxY - cut),
                                CGPoint(x: rect.maxX - cut, y: rect.maxY), CGPoint(x: rect.minX + cut, y: rect.maxY),
                                CGPoint(x: rect.minX, y: rect.maxY - cut), CGPoint(x: rect.minX, y: rect.minY + cut)])
        path.closeSubpath()
        return path
    }

    /// An oval as a hand draws one: lopsided, a little egg-shaped, with a few slow swells
    /// round it, all outward of the ellipse, so the words stay clear; its own from its
    /// balloon's numbers.
    static func wobbly(around e: Ellipse, random: inout BalloonRandom) -> CGPath {
        let swells: [(turns: CGFloat, depth: CGFloat, phase: CGFloat)] = [
            (1, random.next(in: 0.015...0.03), random.next(in: 0...(2 * .pi))),
            (2, random.next(in: 0.03...0.05), random.next(in: 0...(2 * .pi))),
            (3, random.next(in: 0.015...0.03), random.next(in: 0...(2 * .pi))),
            (5, random.next(in: 0.006...0.012), random.next(in: 0...(2 * .pi))),
        ]
        let count = 40
        let points = (0..<count).map { i -> CGPoint in
            let angle = CGFloat(i) / CGFloat(count) * 2 * .pi
            let reach = 1 + swells.reduce(0) { $0 + $1.depth * 0.75 * (1 + sin($1.turns * angle + $1.phase)) }
            return point(on: e, at: angle, reach: reach)
        }
        return smoothLoop(through: points)
    }

    /// A closed curve through `points`, each joined to the next by a cubic (Catmull–Rom).
    static func smoothLoop(through points: [CGPoint]) -> CGPath {
        let path = CGMutablePath()
        let n = points.count
        guard n > 2 else { return path }
        path.move(to: points[0])
        for i in 0..<n {
            let p0 = points[(i + n - 1) % n], p1 = points[i], p2 = points[(i + 1) % n], p3 = points[(i + 2) % n]
            path.addCurve(to: p2,
                          control1: CGPoint(x: p1.x + (p2.x - p0.x) / 6, y: p1.y + (p2.y - p0.y) / 6),
                          control2: CGPoint(x: p2.x - (p3.x - p1.x) / 6, y: p2.y - (p3.y - p1.y) / 6))
        }
        path.closeSubpath()
        return path
    }

    /// Points round an ellipse, out and in by turns: a shout's edge. `spacing` is the run
    /// between neighbouring points in sizes; `jitter` moves each along by up to that share of
    /// a step; the reaches are how far out the points go, the outer and the inner.
    static func spikes(around e: Ellipse, size: CGFloat, spacing: CGFloat, least: Int, jitter: CGFloat,
                       outer: ClosedRange<CGFloat>, inner: ClosedRange<CGFloat>, random: inout BalloonRandom) -> CGPath {
        let count = max(least, Int(perimeter(of: e) / (size * spacing)) / 2 * 2)
        let step = 2 * CGFloat.pi / CGFloat(count)
        let start = random.next(in: 0...(2 * .pi))
        let path = CGMutablePath()
        for i in 0..<count {
            let angle = start + (CGFloat(i) + (jitter > 0 ? random.next(in: -jitter...jitter) : 0)) * step
            let reach = random.next(in: i % 2 == 0 ? outer : inner)
            let p = point(on: e, at: angle, reach: reach)
            if i == 0 { path.move(to: p) } else { path.addLine(to: p) }
        }
        path.closeSubpath()
        return path
    }

    /// Where the line from `from` toward `to` first leaves `shape`, `from` being inside it.
    static func exit(of shape: CGPath, from: CGPoint, toward to: CGPoint, step: CGFloat) -> CGPoint {
        let length = hypot(to.x - from.x, to.y - from.y)
        guard length > 0 else { return from }
        func at(_ d: CGFloat) -> CGPoint {
            CGPoint(x: from.x + (to.x - from.x) * d / length, y: from.y + (to.y - from.y) * d / length)
        }
        var inside: CGFloat = 0, outside = length
        var d = max(step, 0.5)
        while d < length {
            if !shape.contains(at(d)) { outside = d; break }
            inside = d
            d += max(step, 0.5)
        }
        for _ in 0..<12 {
            let middle = (inside + outside) / 2
            if shape.contains(at(middle)) { inside = middle } else { outside = middle }
        }
        return at(outside)
    }

    /// A tail like lightning from its base, `leftRoot` to the left of the way out and
    /// `rightRoot` to the right, to `tip`: a band that zigs aside and zags back on its way,
    /// narrowing to a point; closed back through `through`, inside the body, so the union
    /// fills its root.
    static func lightning(left leftRoot: CGPoint, right rightRoot: CGPoint, through: CGPoint, to tip: CGPoint,
                          size: CGFloat) -> CGPath? {
        let base = CGPoint(x: (leftRoot.x + rightRoot.x) / 2, y: (leftRoot.y + rightRoot.y) / 2)
        let length = hypot(tip.x - base.x, tip.y - base.y)
        guard length > 0 else { return nil }
        let u = CGPoint(x: (tip.x - base.x) / length, y: (tip.y - base.y) / length)
        let n = CGPoint(x: -u.y, y: u.x)
        let half = hypot(leftRoot.x - rightRoot.x, leftRoot.y - rightRoot.y) / 2
        let swing = min(length * 0.12, size)
        // The band's middle line, out, aside, back across and on to the tip, each leg leaning
        // well short of square; and its half-width at each joint
        let joints: [(along: CGFloat, aside: CGFloat, width: CGFloat)] = [(0.38, 1, 0.62), (0.62, -1, 0.42)]
        let middle = [base] + joints.map { CGPoint(x: base.x + u.x * length * $0.along + n.x * swing * $0.aside,
                                                   y: base.y + u.y * length * $0.along + n.y * swing * $0.aside) } + [tip]
        func normal(_ a: CGPoint, _ b: CGPoint) -> CGPoint {
            let d = max(hypot(b.x - a.x, b.y - a.y), 0.001)
            return CGPoint(x: -(b.y - a.y) / d, y: (b.x - a.x) / d)
        }
        var left: [CGPoint] = [], right: [CGPoint] = []
        for (i, joint) in joints.enumerated() {
            // Mitred: out along the bisector of the two legs' normals, as far as keeps the width
            let p = middle[i + 1]
            let n1 = normal(middle[i], p), n2 = normal(p, middle[i + 2])
            var m = CGPoint(x: n1.x + n2.x, y: n1.y + n2.y)
            let ml = max(hypot(m.x, m.y), 0.001)
            m = CGPoint(x: m.x / ml, y: m.y / ml)
            let reach = half * joint.width / max(0.5, m.x * n1.x + m.y * n1.y)
            left.append(CGPoint(x: p.x + m.x * reach, y: p.y + m.y * reach))
            right.append(CGPoint(x: p.x - m.x * reach, y: p.y - m.y * reach))
        }
        let path = CGMutablePath()
        path.addLines(between: [leftRoot] + left + [tip] + right.reversed() + [rightRoot, through])
        path.closeSubpath()
        return path
    }
}

extension BalloonLine {
    /// `outline` moved in and out along itself, for a wavy or an electric line: flattened,
    /// walked at even steps, a whole number of waves round each loop, each point pushed out
    /// or in along the outline's normal; the waves sized by the line's width, so they read
    /// at any size. A loop too short for six waves, or any other line, is left as it is.
    func reshaping(_ outline: CGPath, lineWidth: CGFloat) -> CGPath {
        guard reshapes else { return outline }
        let wave = self == .wavy ? lineWidth * 7 : lineWidth * 3.6
        let depth = self == .wavy ? lineWidth * 1.1 : lineWidth * 1.25
        // Points per wave: a wavy line's smooth, an electric one's its zig and its zag
        let perWave = self == .wavy ? 12 : 2
        let result = CGMutablePath()
        for loop in Self.loops(of: outline) {
            let lengths = loop.indices.map { i in hypot(loop[(i + 1) % loop.count].x - loop[i].x, loop[(i + 1) % loop.count].y - loop[i].y) }
            let perimeter = lengths.reduce(0, +)
            let waves = Int((perimeter / wave).rounded())
            guard waves >= 6 else {
                result.addLines(between: loop)
                result.closeSubpath()
                continue
            }
            // Evenly along the loop
            let count = waves * perWave
            let step = perimeter / CGFloat(count)
            var samples: [CGPoint] = []
            var edge = 0, into: CGFloat = 0
            for k in 0..<count {
                var target = CGFloat(k) * step - into
                while edge < loop.count, target > lengths[edge] {
                    target -= lengths[edge]
                    into += lengths[edge]
                    edge += 1
                }
                let a = loop[edge % loop.count], b = loop[(edge + 1) % loop.count]
                let f = lengths[edge % loop.count] > 0 ? target / lengths[edge % loop.count] : 0
                samples.append(CGPoint(x: a.x + (b.x - a.x) * f, y: a.y + (b.y - a.y) * f))
            }
            // Outward: to the right of the way round an anticlockwise loop, the left of a clockwise one
            let outward: CGFloat = GlyphOutline.signedArea(loop) > 0 ? 1 : -1
            var moved: [CGPoint] = []
            for k in 0..<count {
                let before = samples[(k + count - 1) % count], after = samples[(k + 1) % count]
                let dx = after.x - before.x, dy = after.y - before.y
                let d = max(hypot(dx, dy), 0.001)
                let normal = CGPoint(x: dy / d * outward, y: -dx / d * outward)
                let push = self == .wavy ? depth * sin(2 * .pi * CGFloat(k) / CGFloat(perWave)) : (k % 2 == 0 ? depth : -depth)
                moved.append(CGPoint(x: samples[k].x + normal.x * push, y: samples[k].y + normal.y * push))
            }
            if self == .wavy {
                result.addPath(BalloonGeometry.smoothLoop(through: moved))
            } else {
                result.addLines(between: moved)
                result.closeSubpath()
            }
        }
        return result
    }

    /// `path`'s closed loops as points.
    private static func loops(of path: CGPath) -> [[CGPoint]] {
        var loops: [[CGPoint]] = []
        var current: [CGPoint] = []
        path.flattened(threshold: 0.25).applyWithBlock { element in
            let e = element.pointee
            switch e.type {
            case .moveToPoint:
                if current.count > 2 { loops.append(current) }
                current = [e.points[0]]
            case .addLineToPoint:
                current.append(e.points[0])
            case .closeSubpath:
                if current.count > 2 { loops.append(current) }
                current = []
            default:
                break // flattened: only lines
            }
        }
        if current.count > 2 { loops.append(current) }
        // A loop that ends where it began, as a flattened curve does, without the repeat
        return loops.map { loop in
            if let first = loop.first, let last = loop.last, loop.count > 3, hypot(first.x - last.x, first.y - last.y) < 0.01 {
                return Array(loop.dropLast())
            }
            return loop
        }
    }
}
