import CoreGraphics
import CoreText
import Foundation

/// What a balloon is: one that speaks, thinks or shouts, with a tail to its speaker; a
/// caption box; or a sound effect, words with no body.
public enum BalloonStyle: String, Codable, CaseIterable, Identifiable {
    case speech, thought, shout, caption, sound

    public var id: String { rawValue }
    /// Whether a tail points from it to someone.
    public var hasTail: Bool { self == .speech || self == .thought || self == .shout }
    public var systemImage: String {
        switch self {
        case .speech: return "bubble.left"
        case .thought: return "cloud"
        case .shout: return "burst"
        case .caption: return "rectangle"
        case .sound: return "textformat"
        }
    }
}

/// The faces lettering is set in: the system's, on the Mac and on iPad alike, so nothing
/// is bundled or licensed. A comic's own lettering face can join them.
public enum LetteringFace: String, Codable, CaseIterable, Identifiable {
    case dialogue, hand, marker, clean

    public var id: String { rawValue }
    public var postScriptName: String {
        switch self {
        case .dialogue: return "ChalkboardSE-Bold"
        case .hand: return "Noteworthy-Bold"
        case .marker: return "MarkerFelt-Wide"
        case .clean: return "AvenirNextCondensed-DemiBold"
        }
    }
}

/// A balloon on a lettering layer: its words and how they are set, where it sits and
/// where its tail points. Canvas pixels, y running up, as the guides are.
public struct Balloon: Codable, Equatable, Identifiable {
    public var id = UUID()
    public var style: BalloonStyle
    /// The middle of the words.
    public var center: CGPoint
    public var text: String
    /// How wide the words run before they wrap.
    public var wrapWidth: CGFloat
    public var face: LetteringFace
    /// The face's size, in canvas pixels.
    public var fontSize: CGFloat
    /// Set in capitals, as comics are lettered.
    public var allCaps: Bool
    /// Where the tail points; nil for none.
    public var tail: CGPoint?

    public init(style: BalloonStyle, center: CGPoint, text: String = "", wrapWidth: CGFloat, face: LetteringFace,
                fontSize: CGFloat, allCaps: Bool = true, tail: CGPoint? = nil) {
        self.style = style
        self.center = center
        self.text = text
        self.wrapWidth = wrapWidth
        self.face = face
        self.fontSize = fontSize
        self.allCaps = allCaps
        self.tail = tail
    }

    /// A lettering size for a canvas `canvasWidth` across: about 8 points at print size on
    /// a US comic page at 400 dpi, and the same share of any other.
    public static func fontSize(canvasWidth: CGFloat) -> CGFloat {
        max(12, (canvasWidth * 0.016).rounded())
    }

    /// A new balloon at `point` in `style`: words wrapping at about nine of the size, and
    /// for a balloon that speaks, a tail down and to the left of it.
    public static func new(_ style: BalloonStyle, at point: CGPoint, face: LetteringFace, fontSize: CGFloat,
                           allCaps: Bool) -> Balloon {
        var balloon = Balloon(style: style, center: point, wrapWidth: fontSize * 9, face: face,
                              fontSize: style == .sound ? fontSize * 2 : fontSize, allCaps: allCaps)
        if style.hasTail {
            balloon.tail = CGPoint(x: point.x - fontSize * 2, y: point.y - fontSize * 5)
        }
        return balloon
    }

    /// The words as they are set.
    public var displayText: String { allCaps ? text.uppercased() : text }
}

/// Everything drawn of a balloon, worked out once: the words set at their width, the
/// body around them with its tail joined on as one outline, and where it can be picked up.
public struct BalloonLayout {
    public let balloon: Balloon
    /// The words' box, as tight as they are set.
    public let textBox: CGRect
    /// The outline, body and tail as one; empty for a sound effect.
    public let body: CGPath
    /// The outline's width.
    public let lineWidth: CGFloat
    /// What drawing it can touch, outline and words.
    public let bounds: CGRect
    private let frame: CTFrame?

    public init(_ balloon: Balloon) {
        self.balloon = balloon
        let size = max(1, balloon.fontSize)
        let font = CTFontCreateWithName(balloon.face.postScriptName as CFString, size, nil)
        var alignment = CTTextAlignment.center
        let paragraph: CTParagraphStyle = withUnsafePointer(to: &alignment) { pointer in
            var setting = CTParagraphStyleSetting(spec: .alignment, valueSize: MemoryLayout<CTTextAlignment>.size, value: pointer)
            return CTParagraphStyleCreate(&setting, 1)
        }
        // An empty balloon is drawn the size of a short word, so it can be seen and found
        let words = balloon.displayText
        let measured = words.isEmpty ? "WORD" : words
        func attributed(_ string: String) -> NSAttributedString {
            NSAttributedString(string: string, attributes: [
                NSAttributedString.Key(kCTFontAttributeName as String): font,
                NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(gray: 0, alpha: 1),
                NSAttributedString.Key(kCTParagraphStyleAttributeName as String): paragraph,
            ])
        }
        let wrap = max(size, balloon.wrapWidth)
        let setter = CTFramesetterCreateWithAttributedString(attributed(measured))
        let fitted = CTFramesetterSuggestFrameSizeWithConstraints(setter, CFRange(location: 0, length: 0), nil,
                                                                  CGSize(width: wrap, height: .greatestFiniteMagnitude), nil)
        let textWidth = ceil(fitted.width), textHeight = ceil(fitted.height)
        let center = balloon.center
        textBox = CGRect(x: center.x - textWidth / 2, y: center.y - textHeight / 2, width: textWidth, height: textHeight)
        if words.isEmpty {
            frame = nil
        } else {
            // Set at the wrap width, centred, so the lines break where they were measured
            let frameRect = CGRect(x: center.x - wrap / 2, y: textBox.minY, width: wrap, height: textHeight + 1)
            frame = CTFramesetterCreateFrame(CTFramesetterCreateWithAttributedString(attributed(words)),
                                             CFRange(location: 0, length: 0), CGPath(rect: frameRect, transform: nil), nil)
        }

        lineWidth = max(1.5, (size * 0.075).rounded(.up))
        let pad = size * 0.5
        body = Self.body(of: balloon, around: textBox, pad: pad)
        let outline = balloon.style == .sound ? textBox : body.boundingBoxOfPath
        bounds = outline.union(textBox).insetBy(dx: -lineWidth - 2, dy: -lineWidth - 2).integral
    }

    /// The ellipse a balloon's words sit in: through the corners of their box and a margin
    /// round it, a little fuller than the box itself.
    static func ellipse(around box: CGRect, pad: CGFloat) -> (center: CGPoint, a: CGFloat, b: CGFloat) {
        (CGPoint(x: box.midX, y: box.midY), (box.width / 2 + pad) * 1.32, (box.height / 2 + pad * 0.8) * 1.32)
    }

    private static func body(of balloon: Balloon, around box: CGRect, pad: CGFloat) -> CGPath {
        let size = balloon.fontSize
        switch balloon.style {
        case .sound:
            return CGMutablePath()
        case .caption:
            return CGPath(rect: box.insetBy(dx: -pad, dy: -pad * 0.8), transform: nil)
        case .speech:
            let (c, a, b) = ellipse(around: box, pad: pad)
            let shape = CGPath(ellipseIn: CGRect(x: c.x - a, y: c.y - b, width: 2 * a, height: 2 * b), transform: nil)
            guard let tip = balloon.tail, let tail = wedge(from: (c, a, b), to: tip, curved: true) else { return shape }
            return shape.union(tail)
        case .shout:
            let (c, a, b) = ellipse(around: box, pad: pad)
            let star = CGMutablePath()
            let perimeter = CGFloat.pi * (3 * (a + b) - ((3 * a + b) * (a + 3 * b)).squareRoot())
            let points = max(20, Int(perimeter / (size * 0.9)) / 2 * 2)
            for i in 0..<points {
                let t = CGFloat(i) / CGFloat(points) * 2 * .pi
                let reach: CGFloat = i % 2 == 0 ? 1.24 : 1.0
                let p = CGPoint(x: c.x + a * reach * cos(t), y: c.y + b * reach * sin(t))
                if i == 0 { star.move(to: p) } else { star.addLine(to: p) }
            }
            star.closeSubpath()
            guard let tip = balloon.tail, let tail = wedge(from: (c, a, b), to: tip, curved: false) else { return star }
            return star.union(tail)
        case .thought:
            let (c, a, b) = ellipse(around: box, pad: pad)
            // Its own irregular cloud, the same every time it is drawn
            var random = BalloonRandom(balloon.id)
            let shape = CGMutablePath()
            shape.addPath(scallops(around: (c, a, b), size: size, random: &random))
            if let tip = balloon.tail, outside(tip, of: (c, a, b)) {
                // Small ovals from just clear of the cloud toward the thinker, each smaller,
                // with air between them: three if there is room, else two smaller, or one
                let edge = point(on: (c, a, b), toward: tip)
                let distance = hypot(tip.x - edge.x, tip.y - edge.y)
                // Past the scallops, which bulge up to a size or so beyond the ellipse
                let clear = size * 1.9
                let room = distance - clear
                let gap = size * 0.3
                let direction = CGPoint(x: (tip.x - edge.x) / max(distance, 0.001), y: (tip.y - edge.y) / max(distance, 0.001))
                // An oval's length along the way it is going, about
                func length(_ r: CGFloat) -> CGFloat { 2 * r * (1.25 * abs(direction.x) + 0.9 * abs(direction.y)) }
                let choices: [[CGFloat]] = [[0.62, 0.42, 0.26], [0.45, 0.28], [0.3]].map { $0.map { $0 * size } }
                if let radii = choices.first(where: { r in r.map(length).reduce(0, +) + gap * CGFloat(r.count - 1) <= room }) {
                    var along = clear
                    for r in radii {
                        let half = length(r) / 2
                        let p = CGPoint(x: edge.x + direction.x * (along + half), y: edge.y + direction.y * (along + half))
                        shape.addEllipse(in: CGRect(x: p.x - r * 1.25, y: p.y - r * 0.9, width: r * 2.5, height: r * 1.8))
                        along += 2 * half + gap
                    }
                }
            }
            return shape
        }
    }

    /// A thought's cloud: scallops round an ellipse, of uneven widths and heights, each a
    /// round bulge meeting the next in a sharp point turned in, as a letterer draws them,
    /// not a ring of equal circles.
    private static func scallops(around e: (center: CGPoint, a: CGFloat, b: CGFloat), size: CGFloat,
                                 random: inout BalloonRandom) -> CGPath {
        let (c, a, b) = e
        let perimeter = CGFloat.pi * (3 * (a + b) - ((3 * a + b) * (a + 3 * b)).squareRoot())
        let count = max(7, Int((perimeter / (size * 2.1)).rounded()))
        // Uneven steps round the ellipse: some scallops wide, some narrow
        let steps = (0..<count).map { _ in random.next(in: 0.65...1.35) }
        let total = steps.reduce(0, +)
        var angle = random.next(in: 0...(2 * .pi))
        var points: [CGPoint] = []
        for step in steps {
            let reach = random.next(in: 0.97...1.03)
            points.append(CGPoint(x: c.x + a * reach * cos(angle), y: c.y + b * reach * sin(angle)))
            angle += step / total * 2 * .pi
        }
        let path = CGMutablePath()
        path.move(to: points[0])
        for i in 0..<count {
            let p = points[i], q = points[(i + 1) % count]
            let dx = q.x - p.x, dy = q.y - p.y
            let chord = max(hypot(dx, dy), 0.001)
            // Out, away from the middle
            var n = CGPoint(x: dy / chord, y: -dx / chord)
            let mid = CGPoint(x: (p.x + q.x) / 2 - c.x, y: (p.y + q.y) / 2 - c.y)
            if mid.x * n.x + mid.y * n.y < 0 { n = CGPoint(x: -n.x, y: -n.y) }
            // A cubic's controls straight out from its ends: a round bulge about this high
            let height = chord * random.next(in: 0.36...0.52) / 0.75
            path.addCurve(to: q,
                          control1: CGPoint(x: p.x + n.x * height + dx * 0.04, y: p.y + n.y * height + dy * 0.04),
                          control2: CGPoint(x: q.x + n.x * height - dx * 0.04, y: q.y + n.y * height - dy * 0.04))
        }
        path.closeSubpath()
        return path
    }

    private static func outside(_ p: CGPoint, of e: (center: CGPoint, a: CGFloat, b: CGFloat)) -> Bool {
        let dx = (p.x - e.center.x) / e.a, dy = (p.y - e.center.y) / e.b
        return dx * dx + dy * dy > 1.15
    }

    private static func point(on e: (center: CGPoint, a: CGFloat, b: CGFloat), toward p: CGPoint) -> CGPoint {
        let t = atan2((p.y - e.center.y) / e.b, (p.x - e.center.x) / e.a)
        return CGPoint(x: e.center.x + e.a * cos(t), y: e.center.y + e.b * sin(t))
    }

    /// A tail from an ellipse's edge to `tip`: a wedge whose base sits on the edge either
    /// side of where the tip points, its sides drawn in toward the middle so it tapers,
    /// or straight for a shout. Nil when the tip is inside the body.
    private static func wedge(from e: (center: CGPoint, a: CGFloat, b: CGFloat), to tip: CGPoint, curved: Bool) -> CGPath? {
        guard outside(tip, of: e) else { return nil }
        let t = atan2((tip.y - e.center.y) / e.b, (tip.x - e.center.x) / e.a)
        let spread: CGFloat = 0.2
        func edge(_ angle: CGFloat) -> CGPoint {
            CGPoint(x: e.center.x + e.a * 0.96 * cos(angle), y: e.center.y + e.b * 0.96 * sin(angle))
        }
        let left = edge(t - spread), right = edge(t + spread)
        let middle = CGPoint(x: (left.x + right.x) / 2, y: (left.y + right.y) / 2)
        func control(_ base: CGPoint) -> CGPoint {
            // Halfway along the side, drawn a little toward the tail's middle line
            let side = CGPoint(x: (base.x + tip.x) / 2, y: (base.y + tip.y) / 2)
            let axis = CGPoint(x: (middle.x + tip.x) / 2, y: (middle.y + tip.y) / 2)
            return CGPoint(x: side.x + (axis.x - side.x) * 0.35, y: side.y + (axis.y - side.y) * 0.35)
        }
        let path = CGMutablePath()
        path.move(to: left)
        if curved {
            path.addQuadCurve(to: tip, control: control(left))
            path.addQuadCurve(to: right, control: control(right))
        } else {
            path.addLine(to: tip)
            path.addLine(to: right)
        }
        // Back through the body, so the union fills the wedge's root
        path.addLine(to: e.center)
        path.closeSubpath()
        return path
    }

    /// Whether `point` picks this balloon up: on its body, or on its words.
    public func contains(_ point: CGPoint) -> Bool {
        if balloon.style == .sound {
            return textBox.insetBy(dx: -balloon.fontSize * 0.4, dy: -balloon.fontSize * 0.4).contains(point)
        }
        return body.contains(point) || textBox.contains(point)
    }

    /// The handle that points the tail, at its tip; nil for a style with none.
    public var tailHandle: CGPoint? { balloon.style.hasTail ? balloon.tail : nil }

    /// The handle that sets how wide the words run: at the right of the wrap width.
    public var widthHandle: CGPoint {
        CGPoint(x: balloon.center.x + max(balloon.fontSize, balloon.wrapWidth) / 2, y: balloon.center.y)
    }

    /// Draws the balloon into `context`, whose coordinates are canvas pixels with y up:
    /// a white body with a black outline, and the words in black over it.
    public func draw(in context: CGContext) {
        if balloon.style != .sound {
            context.addPath(body)
            context.setFillColor(CGColor(gray: 1, alpha: 1))
            context.fillPath()
            context.addPath(body)
            context.setStrokeColor(CGColor(gray: 0, alpha: 1))
            context.setLineWidth(lineWidth)
            context.setLineJoin(.round)
            context.strokePath()
        }
        if let frame {
            context.saveGState()
            context.textMatrix = .identity
            CTFrameDraw(frame, context)
            context.restoreGState()
        }
    }
}

/// The numbers a balloon's irregular shapes are drawn from: the same from the same balloon,
/// on every launch and every device (SplitMix64, seeded from its id).
struct BalloonRandom {
    private var state: UInt64

    init(_ id: UUID) {
        var hash: UInt64 = 0xcbf29ce484222325
        withUnsafeBytes(of: id.uuid) { for byte in $0 { hash = (hash ^ UInt64(byte)) &* 0x100000001b3 } }
        state = hash
    }

    mutating func next() -> UInt64 {
        state &+= 0x9E3779B97F4A7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        return z ^ (z >> 31)
    }

    mutating func next(in range: ClosedRange<CGFloat>) -> CGFloat {
        range.lowerBound + CGFloat(Double(next() >> 11) / Double(1 << 53)) * (range.upperBound - range.lowerBound)
    }
}
