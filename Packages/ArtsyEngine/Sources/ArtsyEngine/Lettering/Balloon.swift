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
    /// A font the artist drew (`DrawnFonts`), set in place of the face, which stays for the
    /// characters the font lacks and for when the font is gone. Nil for the face alone.
    public var drawnFont: UUID?
    /// The face's size, in canvas pixels.
    public var fontSize: CGFloat
    /// Set in capitals, as comics are lettered.
    public var allCaps: Bool
    /// Where the tail points; nil for none.
    public var tail: CGPoint?
    /// The words in bold and in italic: a drawn font's own bold and italic, a face's where it
    /// has one, else drawn heavier or slanted. Words between asterisks are bold italic anyway.
    public var bold: Bool
    public var italic: Bool
    /// Its shape, line, fill and tail's shape and width (see `BalloonLook`).
    public var look: BalloonLook
    /// Whether its tail's tip is pinned where it is on the page, pointing at its speaker, so
    /// it stays there when the balloon moves; unpinned, it goes with the balloon.
    public var tailPinned: Bool
    /// Its body as the artist drew it, in place of its look's shape; nil for the look's.
    public var drawn: DrawnOutline?

    public init(style: BalloonStyle, center: CGPoint, text: String = "", wrapWidth: CGFloat, face: LetteringFace,
                drawnFont: UUID? = nil, fontSize: CGFloat, allCaps: Bool = true, tail: CGPoint? = nil,
                bold: Bool = false, italic: Bool = false, look: BalloonLook = BalloonLook(), tailPinned: Bool = false,
                drawn: DrawnOutline? = nil) {
        self.style = style
        self.center = center
        self.text = text
        self.wrapWidth = wrapWidth
        self.face = face
        self.drawnFont = drawnFont
        self.fontSize = fontSize
        self.allCaps = allCaps
        self.tail = tail
        self.bold = bold
        self.italic = italic
        self.look = look
        self.tailPinned = tailPinned
        self.drawn = drawn
    }

    // Balloons saved before bold and italic read as neither, and before looks as the plain
    // look; older builds ignore them. A look's part a later build adds reads as the plain one.
    private enum CodingKeys: String, CodingKey {
        case id, style, center, text, wrapWidth, face, drawnFont, fontSize, allCaps, tail, bold, italic
        case shape, line, fill, tailShape, tailWidth, tailBase, tailPinned, drawn
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        style = try c.decode(BalloonStyle.self, forKey: .style)
        center = try c.decode(CGPoint.self, forKey: .center)
        text = try c.decode(String.self, forKey: .text)
        wrapWidth = try c.decode(CGFloat.self, forKey: .wrapWidth)
        face = try c.decode(LetteringFace.self, forKey: .face)
        drawnFont = try c.decodeIfPresent(UUID.self, forKey: .drawnFont)
        fontSize = try c.decode(CGFloat.self, forKey: .fontSize)
        allCaps = try c.decode(Bool.self, forKey: .allCaps)
        tail = try c.decodeIfPresent(CGPoint.self, forKey: .tail)
        bold = try c.decodeIfPresent(Bool.self, forKey: .bold) ?? false
        italic = try c.decodeIfPresent(Bool.self, forKey: .italic) ?? false
        func part<T: RawRepresentable>(_ key: CodingKeys) throws -> T? where T.RawValue == String {
            try c.decodeIfPresent(String.self, forKey: key).flatMap(T.init(rawValue:))
        }
        look = BalloonLook(shape: try part(.shape), line: try part(.line) ?? .solid, fill: try part(.fill) ?? .white,
                           tail: try part(.tailShape), tailWidth: try c.decodeIfPresent(CGFloat.self, forKey: .tailWidth) ?? 1,
                           tailBase: try c.decodeIfPresent(CGFloat.self, forKey: .tailBase))
        tailPinned = try c.decodeIfPresent(Bool.self, forKey: .tailPinned) ?? false
        drawn = try c.decodeIfPresent(DrawnOutline.self, forKey: .drawn)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(style, forKey: .style)
        try c.encode(center, forKey: .center)
        try c.encode(text, forKey: .text)
        try c.encode(wrapWidth, forKey: .wrapWidth)
        try c.encode(face, forKey: .face)
        try c.encodeIfPresent(drawnFont, forKey: .drawnFont)
        try c.encode(fontSize, forKey: .fontSize)
        try c.encode(allCaps, forKey: .allCaps)
        try c.encodeIfPresent(tail, forKey: .tail)
        if bold { try c.encode(bold, forKey: .bold) }
        if italic { try c.encode(italic, forKey: .italic) }
        try c.encodeIfPresent(look.shape?.rawValue, forKey: .shape)
        if look.line != .solid { try c.encode(look.line.rawValue, forKey: .line) }
        if look.fill != .white { try c.encode(look.fill.rawValue, forKey: .fill) }
        try c.encodeIfPresent(look.tail?.rawValue, forKey: .tailShape)
        if look.tailWidth != 1 { try c.encode(look.tailWidth, forKey: .tailWidth) }
        try c.encodeIfPresent(look.tailBase, forKey: .tailBase)
        if tailPinned { try c.encode(tailPinned, forKey: .tailPinned) }
        try c.encodeIfPresent(drawn, forKey: .drawn)
    }

    /// A lettering size for a canvas `canvasWidth` across: about 8 points at print size on
    /// a US comic page at 400 dpi, and the same share of any other.
    public static func fontSize(canvasWidth: CGFloat) -> CGFloat {
        max(12, (canvasWidth * 0.016).rounded())
    }

    /// A new balloon at `point` in `style` and `look`: words wrapping at about nine of the
    /// size, and for a balloon that speaks, a tail down and to the left of it.
    public static func new(_ style: BalloonStyle, at point: CGPoint, face: LetteringFace, drawnFont: UUID? = nil,
                           fontSize: CGFloat, allCaps: Bool, look: BalloonLook = BalloonLook()) -> Balloon {
        var balloon = Balloon(style: style, center: point, wrapWidth: fontSize * 9, face: face, drawnFont: drawnFont,
                              fontSize: style == .sound ? fontSize * 2 : fontSize, allCaps: allCaps, look: look)
        if style.hasTail {
            balloon.tail = CGPoint(x: point.x - fontSize * 2, y: point.y - fontSize * 5)
        }
        return balloon
    }

    /// The words as they are set.
    public var displayText: String { allCaps ? text.uppercased() : text }

    /// The words in runs, stressed or not: a word or words between asterisks are stressed,
    /// as a letterer sets them in bold italic, the asterisks gone. An asterisk with no partner
    /// after it stays, as a footnote's does.
    public static func stressRuns(in text: String) -> [(text: String, stressed: Bool)] {
        var runs: [(text: String, stressed: Bool)] = []
        var current = "", stressed = false
        let characters = Array(text)
        func flush() {
            if !current.isEmpty { runs.append((current, stressed)) }
            current = ""
        }
        for (i, character) in characters.enumerated() {
            if character == "*" {
                if stressed {
                    flush()
                    stressed = false
                    continue
                }
                if characters[(i + 1)...].contains("*") {
                    flush()
                    stressed = true
                    continue
                }
            }
            current.append(character)
        }
        flush()
        return runs
    }
}

/// The fonts a balloon's words are set in, by style: a drawn font's own family, an imported
/// font or a face with a heavier or slanted stand-in for a member it lacks.
enum LetteringType {
    /// The lean of a stand-in italic.
    static let slant: CGFloat = tan(12 * .pi / 180)

    /// The font for `balloon`'s words in `style` at `size`, and whether to draw them heavier
    /// for a bold the font does not have.
    static func font(for balloon: Balloon, size: CGFloat, style: DrawnFontStyle) -> (font: CTFont, heavier: Bool) {
        let face = balloon.face.postScriptName
        if let id = balloon.drawnFont {
            // Characters a drawn font lacks in the face's own italic, where it has one
            let fallback = style.isItalic
                ? standIn(CTFontCreateWithName(face as CFString, size, nil), style: .italic).font : nil
            let fallbackName = fallback.map { CTFontCopyPostScriptName($0) as String } ?? face
            if let exact = DrawnFonts.font(id: id, size: size, style: style, fallback: fallbackName) { return (exact, false) }
            if let regular = DrawnFonts.font(id: id, size: size, fallback: face) { return standIn(regular, style: style) }
        }
        let base = CTFontCreateWithName(face as CFString, size, nil)
        guard style != .regular else { return (base, false) }
        // The faces are their families' bold cuts already: bold is drawn heavier still
        let (font, _) = standIn(base, style: .italic)
        return (style.isItalic ? font : base, style.isBold)
    }

    /// `font`'s `style`: its family's own member where there is one, else slanted, and drawn
    /// heavier for a bold it lacks.
    static func standIn(_ font: CTFont, style: DrawnFontStyle) -> (font: CTFont, heavier: Bool) {
        var result = font
        if style.isItalic {
            if let italic = CTFontCreateCopyWithSymbolicTraits(font, 0, nil, .traitItalic, .traitItalic),
               CTFontGetSymbolicTraits(italic).contains(.traitItalic) {
                result = italic
            } else {
                var matrix = CGAffineTransform(a: 1, b: 0, c: slant, d: 1, tx: 0, ty: 0)
                result = CTFontCreateCopyWithAttributes(font, 0, &matrix, nil)
            }
        }
        var heavier = false
        if style.isBold {
            if let bold = CTFontCreateCopyWithSymbolicTraits(result, 0, nil, .traitBold, .traitBold),
               CTFontGetSymbolicTraits(bold).contains(.traitBold), !CTFontGetSymbolicTraits(font).contains(.traitBold) {
                result = bold
            } else {
                heavier = true
            }
        }
        return (result, heavier)
    }
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
    /// The ends of the tail's base, the one to the right of the way to the tip first, for a
    /// wedge or a lightning tail; nil for bubbles or no tail.
    public let base: (right: CGPoint, left: CGPoint)?
    private let frame: CTFrame?

    public init(_ balloon: Balloon) {
        self.balloon = balloon
        let size = max(1, balloon.fontSize)
        var alignment = CTTextAlignment.center
        let paragraph: CTParagraphStyle = withUnsafePointer(to: &alignment) { pointer in
            var setting = CTParagraphStyleSetting(spec: .alignment, valueSize: MemoryLayout<CTTextAlignment>.size, value: pointer)
            return CTParagraphStyleCreate(&setting, 1)
        }
        // The words in runs, stressed words bold italic, a drawn font's repeats in its other
        // versions; an empty balloon is drawn the size of a short word, so it can be seen
        var runs = Balloon.stressRuns(in: balloon.displayText)
        let words = runs.map(\.text).joined()
        if let id = balloon.drawnFont {
            var varied = Array(DrawnFonts.vary(words, font: id))
            runs = runs.map { run in
                let taken = String(varied.prefix(run.text.count))
                varied.removeFirst(min(run.text.count, varied.count))
                return (taken, run.stressed)
            }
        }
        let measured = words.isEmpty ? [(text: "WORD", stressed: false)] : runs
        // Black words, or white in a black balloon
        let ink = balloon.style == .sound ? CGColor(gray: 0, alpha: 1) : balloon.look.fill.wordsColor
        func attributed(_ runs: [(text: String, stressed: Bool)]) -> NSAttributedString {
            let result = NSMutableAttributedString()
            for run in runs {
                let style = DrawnFontStyle(bold: balloon.bold || run.stressed, italic: balloon.italic || run.stressed)
                let (font, heavier) = LetteringType.font(for: balloon, size: size, style: style)
                var attributes: [NSAttributedString.Key: Any] = [
                    NSAttributedString.Key(kCTFontAttributeName as String): font,
                    NSAttributedString.Key(kCTForegroundColorAttributeName as String): ink,
                    NSAttributedString.Key(kCTParagraphStyleAttributeName as String): paragraph,
                ]
                if heavier {
                    // Filled and outlined: heavier by a twentieth of the size
                    attributes[NSAttributedString.Key(kCTStrokeWidthAttributeName as String)] = -5.0
                    attributes[NSAttributedString.Key(kCTStrokeColorAttributeName as String)] = ink
                }
                result.append(NSAttributedString(string: run.text, attributes: attributes))
            }
            return result
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
            frame = CTFramesetterCreateFrame(CTFramesetterCreateWithAttributedString(attributed(runs)),
                                             CFRange(location: 0, length: 0), CGPath(rect: frameRect, transform: nil), nil)
        }

        let line = max(1.5, (size * 0.075).rounded(.up))
        lineWidth = balloon.look.line == .heavy ? line * 2 : line
        let pad = size * 0.5
        (body, base) = Self.body(of: balloon, around: textBox, pad: pad, lineWidth: line)
        let outline = balloon.style == .sound ? textBox : body.boundingBoxOfPath
        // A double line reaches half again as far out as one
        let reach = lineWidth * (balloon.look.line == .double ? 1.5 : 1) + 2
        bounds = outline.union(textBox).insetBy(dx: -reach, dy: -reach).integral
    }

    /// The ellipse a balloon's words sit in: through the corners of their box and a margin
    /// round it, a little fuller than the box itself.
    static func ellipse(around box: CGRect, pad: CGFloat) -> (center: CGPoint, a: CGFloat, b: CGFloat) {
        (CGPoint(x: box.midX, y: box.midY), (box.width / 2 + pad) * 1.32, (box.height / 2 + pad * 0.8) * 1.32)
    }

    /// The body, its tail joined on: its shape round the words, reshaped by a wavy or
    /// electric line, and the tail grown from the ellipse inside it, as wide as its look says.
    private static func body(of balloon: Balloon, around box: CGRect, pad: CGFloat, lineWidth: CGFloat)
        -> (CGPath, (right: CGPoint, left: CGPoint)?) {
        guard let shape = balloon.shape else { return (CGMutablePath(), nil) }
        let size = balloon.fontSize
        // Its own irregular shapes, the same every time it is drawn
        var random = BalloonRandom(balloon.id)
        var (outline, e) = Self.outline(shape, of: balloon.style, drawn: balloon.drawn, around: box, pad: pad, size: size,
                                        lineWidth: lineWidth, random: &random)
        outline = balloon.look.line.reshaping(outline, lineWidth: lineWidth)
        guard balloon.style.hasTail, let tip = balloon.tail, outside(tip, of: e), !outline.contains(tip) else { return (outline, nil) }
        let scale = max(0.1, balloon.look.tailWidth)
        let t = atan2((tip.y - e.center.y) / e.b, (tip.x - e.center.x) / e.a)
        // The base's ends, the one to the right of the way out first: either side of where
        // the tip points on the ellipse's edge, in proportion to the body; or as wide as the
        // look sets, square to the way to the tip
        let first: CGPoint, second: CGPoint
        if let width = balloon.look.tailBase {
            (first, second) = BalloonGeometry.base(of: width * size, on: e, facing: t, to: tip)
        } else {
            let spread = min(0.9, 0.2 * scale)
            first = BalloonGeometry.point(on: e, at: t - spread, reach: 0.96)
            second = BalloonGeometry.point(on: e, at: t + spread, reach: 0.96)
        }
        switch balloon.tailShape {
        case .curved, .straight:
            let tail = wedge(first, second, through: e.center, to: tip, curved: balloon.tailShape == .curved)
            return (outline.union(tail), (first, second))
        case .lightning:
            guard let tail = BalloonGeometry.lightning(left: second, right: first, through: e.center, to: tip, size: size) else {
                return (outline, nil)
            }
            return (outline.union(tail), (first, second))
        case .bubbles:
            // From just clear of the body: a cloud's bubbles start past where its scallops can
            // bulge, as they always have; any other's past where the line to the tip leaves it
            let start: CGPoint, clear: CGFloat
            if shape == .cloud, balloon.drawn == nil {
                start = point(on: e, toward: tip)
                clear = size * 1.9
            } else {
                start = BalloonGeometry.exit(of: outline, from: e.center, toward: tip, step: size * 0.2)
                clear = size * 0.45 + lineWidth
            }
            let path = CGMutablePath()
            path.addPath(outline)
            addBubbles(to: path, from: start, clear: clear, to: tip, size: size, scale: scale)
            return (path, nil)
        }
    }

    /// The shape of a body round its words, before its tail, and the ellipse its tail grows
    /// from: the ellipse the words sit in, or the one inside a box. A body drawn by hand is
    /// laid on the ellipse its words need or the one it was drawn round, whichever is larger
    /// each way, and grows its tail from that.
    private static func outline(_ shape: BalloonShape, of style: BalloonStyle, drawn: DrawnOutline?, around box: CGRect,
                                pad: CGFloat, size: CGFloat, lineWidth: CGFloat,
                                random: inout BalloonRandom) -> (CGPath, BalloonGeometry.Ellipse) {
        let e = ellipse(around: box, pad: pad)
        if let drawn {
            let laid: BalloonGeometry.Ellipse = (e.center, max(e.a, drawn.radii.width), max(e.b, drawn.radii.height))
            return (drawn.path(center: laid.center, a: laid.a, b: laid.b), laid)
        }
        let (c, a, b) = e
        switch shape {
        case .oval:
            return (CGPath(ellipseIn: CGRect(x: c.x - a, y: c.y - b, width: 2 * a, height: 2 * b), transform: nil), e)
        case .wobbly:
            return (BalloonGeometry.wobbly(around: e, random: &random), e)
        case .cloud:
            return (scallops(around: e, size: size, spacing: 2.1, steps: 0.65...1.35, heights: 0.36...0.52, random: &random), e)
        case .puffy:
            return (scallops(around: e, size: size, spacing: 3.3, steps: 0.8...1.2, heights: 0.48...0.6, least: 5, random: &random), e)
        case .burst:
            let star = CGMutablePath()
            let points = max(20, Int(BalloonGeometry.perimeter(of: e) / (size * 0.9)) / 2 * 2)
            for i in 0..<points {
                let t = CGFloat(i) / CGFloat(points) * 2 * .pi
                let reach: CGFloat = i % 2 == 0 ? 1.24 : 1.0
                let p = CGPoint(x: c.x + a * reach * cos(t), y: c.y + b * reach * sin(t))
                if i == 0 { star.move(to: p) } else { star.addLine(to: p) }
            }
            star.closeSubpath()
            return (star, e)
        case .jagged:
            return (BalloonGeometry.spikes(around: e, size: size, spacing: 0.5, least: 40, jitter: 0.3,
                                           outer: 1.08...1.16, inner: 1.0...1.03, random: &random), e)
        case .blast:
            return (BalloonGeometry.spikes(around: e, size: size, spacing: 1.6, least: 14, jitter: 0.3,
                                           outer: 1.25...1.65, inner: 1.0...1.05, random: &random), e)
        case .box, .rounded, .slanted, .notched:
            let rect = BalloonGeometry.box(of: style, around: box, pad: pad)
            let inside: BalloonGeometry.Ellipse = (CGPoint(x: rect.midX, y: rect.midY), rect.width / 2, rect.height / 2)
            switch shape {
            case .rounded:
                let path = BalloonGeometry.rounded(around: box, style: style, pad: pad, size: size, clear: lineWidth * 1.5)
                let r = path.boundingBoxOfPath
                return (path, (CGPoint(x: r.midX, y: r.midY), r.width / 2, r.height / 2))
            case .slanted: return (BalloonGeometry.slanted(rect), inside)
            case .notched: return (BalloonGeometry.notched(rect, size: size), inside)
            default: return (CGPath(rect: rect, transform: nil), inside)
            }
        }
    }

    /// Small ovals from `start`, `clear` along the way to `tip` and on toward it, each smaller,
    /// with air between them: three if there is room, else two smaller, or one, or none;
    /// `scale` times the size they would be.
    private static func addBubbles(to path: CGMutablePath, from start: CGPoint, clear: CGFloat, to tip: CGPoint, size: CGFloat,
                                   scale: CGFloat = 1) {
        let distance = hypot(tip.x - start.x, tip.y - start.y)
        let room = distance - clear
        let gap = size * 0.3
        let direction = CGPoint(x: (tip.x - start.x) / max(distance, 0.001), y: (tip.y - start.y) / max(distance, 0.001))
        // An oval's length along the way it is going, about
        func length(_ r: CGFloat) -> CGFloat { 2 * r * (1.25 * abs(direction.x) + 0.9 * abs(direction.y)) }
        let choices: [[CGFloat]] = [[0.62, 0.42, 0.26], [0.45, 0.28], [0.3]].map { $0.map { $0 * size * scale } }
        guard let radii = choices.first(where: { r in r.map(length).reduce(0, +) + gap * CGFloat(r.count - 1) <= room }) else { return }
        var along = clear
        for r in radii {
            let half = length(r) / 2
            let p = CGPoint(x: start.x + direction.x * (along + half), y: start.y + direction.y * (along + half))
            path.addEllipse(in: CGRect(x: p.x - r * 1.25, y: p.y - r * 0.9, width: r * 2.5, height: r * 1.8))
            along += 2 * half + gap
        }
    }

    /// A thought's cloud: scallops round an ellipse, of uneven widths and heights, each a
    /// round bulge meeting the next in a sharp point turned in, as a letterer draws them,
    /// not a ring of equal circles.
    /// `spacing` is a scallop's run in sizes, about; `steps` how uneven their widths are, and
    /// `heights` how far they bulge, in their chords.
    private static func scallops(around e: (center: CGPoint, a: CGFloat, b: CGFloat), size: CGFloat, spacing: CGFloat,
                                 steps stepRange: ClosedRange<CGFloat>, heights: ClosedRange<CGFloat>, least: Int = 7,
                                 random: inout BalloonRandom) -> CGPath {
        let (c, a, b) = e
        let perimeter = BalloonGeometry.perimeter(of: e)
        let count = max(least, Int((perimeter / (size * spacing)).rounded()))
        // Uneven steps round the ellipse: some scallops wide, some narrow
        let steps = (0..<count).map { _ in random.next(in: stepRange) }
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
            let height = chord * random.next(in: heights) / 0.75
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

    /// A tail from the base `first`–`second` to `tip`: a wedge whose sides are drawn in
    /// toward its middle line so it tapers, or straight for a shout; closed back through
    /// `through`, inside the body, so the union fills its root.
    private static func wedge(_ first: CGPoint, _ second: CGPoint, through: CGPoint, to tip: CGPoint, curved: Bool) -> CGPath {
        let middle = CGPoint(x: (first.x + second.x) / 2, y: (first.y + second.y) / 2)
        func control(_ base: CGPoint) -> CGPoint {
            // Halfway along the side, drawn a little toward the tail's middle line
            let side = CGPoint(x: (base.x + tip.x) / 2, y: (base.y + tip.y) / 2)
            let axis = CGPoint(x: (middle.x + tip.x) / 2, y: (middle.y + tip.y) / 2)
            return CGPoint(x: side.x + (axis.x - side.x) * 0.35, y: side.y + (axis.y - side.y) * 0.35)
        }
        let path = CGMutablePath()
        path.move(to: first)
        if curved {
            path.addQuadCurve(to: tip, control: control(first))
            path.addQuadCurve(to: second, control: control(second))
        } else {
            path.addLine(to: tip)
            path.addLine(to: second)
        }
        path.addLine(to: through)
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

    /// The handle that sets how wide the tail's base is, at its left end; nil for bubbles or
    /// no tail.
    public var baseHandle: CGPoint? { base?.left }

    /// How wide the tail's base is, in canvas pixels; nil for bubbles or no tail.
    public var baseWidth: CGFloat? { base.map { hypot($0.left.x - $0.right.x, $0.left.y - $0.right.y) } }

    /// The base's width, in sizes of the lettering, for an end dragged to `point`: twice its
    /// distance from the base's middle along the base, within the narrowest and widest.
    public func baseSize(draggedTo point: CGPoint) -> CGFloat? {
        guard let base, balloon.fontSize > 0 else { return nil }
        let middle = CGPoint(x: (base.left.x + base.right.x) / 2, y: (base.left.y + base.right.y) / 2)
        let length = max(hypot(base.left.x - base.right.x, base.left.y - base.right.y), 0.001)
        let along = CGPoint(x: (base.left.x - base.right.x) / length, y: (base.left.y - base.right.y) / length)
        let half = abs((point.x - middle.x) * along.x + (point.y - middle.y) * along.y)
        let range = BalloonLook.tailBases
        return min(range.upperBound, max(range.lowerBound, 2 * half / balloon.fontSize))
    }


    /// The handle that sets how wide the words run: at the right of the wrap width.
    public var widthHandle: CGPoint {
        CGPoint(x: balloon.center.x + max(balloon.fontSize, balloon.wrapWidth) / 2, y: balloon.center.y)
    }

    /// Draws the balloon into `context`, whose coordinates are canvas pixels with y up:
    /// a white body with a black outline, and the words in black over it.
    public func draw(in context: CGContext) {
        if balloon.style != .sound {
            let look = balloon.look
            context.addPath(body)
            context.setFillColor(look.fill.color)
            context.fillPath()
            if look.line != .none {
                context.saveGState()
                context.setStrokeColor(CGColor(gray: 0, alpha: 1))
                context.setLineJoin(.round)
                switch look.line {
                case .double:
                    // A wide black line with a thin one in the fill along its middle: two lines
                    context.addPath(body)
                    context.setLineWidth(lineWidth * 3)
                    context.strokePath()
                    context.setStrokeColor(look.fill.gapColor)
                case .dashed:
                    context.setLineCap(.round)
                    context.setLineDash(phase: 0, lengths: [lineWidth * 2.6, lineWidth * 3.4])
                default:
                    break
                }
                context.addPath(body)
                context.setLineWidth(lineWidth)
                context.strokePath()
                context.restoreGState()
            }
        }
        if let frame {
            context.saveGState()
            context.textMatrix = .identity
            CTFrameDraw(frame, context)
            context.restoreGState()
        }
    }

    /// The balloon the panel's pictures are of: always the same one, so a picture of a cloud
    /// or a blast keeps its outline.
    private static let previewID = UUID(uuidString: "5F1A9C3E-7B42-4D8E-9A61-2C7E0B3D4F85")!

    /// A small picture of a balloon of `style` in `look`, with no words and, if `tail`, a
    /// tail down to the left, fitted into `width` × `height` pixels and centred, over
    /// nothing: the lettering panel's choices. Laid out in points, `scale` pixels each, so
    /// its line is at least a point and a half and a heavy or electric line reads. Nil for a
    /// sound effect. With `drawn`, the body is that outline, as drawn round words lettered
    /// at `drawnSize`.
    public static func preview(_ style: BalloonStyle, look: BalloonLook, tail: Bool, width: Int, height: Int,
                               scale: CGFloat = 1, drawn: DrawnOutline? = nil, drawnSize: CGFloat = 1) -> CGImage? {
        guard style != .sound, width > 0, height > 0, scale > 0 else { return nil }
        let room = CGSize(width: CGFloat(width) / scale, height: CGFloat(height) / scale)
        func layout(size: CGFloat) -> BalloonLayout {
            var balloon = Balloon(style: style, center: .zero, wrapWidth: size * 9, face: .dialogue, fontSize: size,
                                  allCaps: true, look: look)
            balloon.id = previewID
            if let drawn {
                let k = size / max(drawnSize, 1e-6)
                balloon.drawn = DrawnOutline(points: drawn.points,
                                             radii: CGSize(width: drawn.radii.width * k, height: drawn.radii.height * k))
            }
            // Long enough down and out for bubbles to fit
            if tail, style.hasTail { balloon.tail = CGPoint(x: -size * 3, y: -size * 3) }
            return BalloonLayout(balloon)
        }
        // Sized to fit: measured once at ten, then laid out again at the size that fits
        let trial = layout(size: 10)
        let fit = min(room.width / trial.bounds.width, room.height / trial.bounds.height)
        let fitted = layout(size: max(3, 10 * fit * 0.96))
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                      space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        let bounds = fitted.bounds
        let shrink = min(1, room.width / bounds.width, room.height / bounds.height)
        context.translateBy(x: CGFloat(width) / 2, y: CGFloat(height) / 2)
        context.scaleBy(x: scale * shrink, y: scale * shrink)
        context.translateBy(x: -bounds.midX, y: -bounds.midY)
        fitted.draw(in: context)
        return context.makeImage()
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
