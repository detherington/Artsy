import SwiftUI
import CoreText
import ArtsyEngine
#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// The sheet a character is drawn on, as the Font Studio shows it: white paper with the
/// guides (cap height, the x-height dashed, the baseline darker, the descender), the
/// character printed faintly in a plain face to draw over, the strokes so far in black, and
/// where the letter's spacing ends either side. Drawn the same on the Mac and on iPad, in a
/// square of `side` points, the context's y running up.
enum GlyphSheetDrawing {
    /// The face the character is printed in behind the strokes.
    static let markFace = "AvenirNextCondensed-Medium"

    static func scale(side: CGFloat) -> CGFloat { side / DrawnFont.sheet.width }

    /// Font units for a point in a square of `side`, y running down from its top.
    static func fontPoint(_ p: CGPoint, side: CGFloat) -> CGPoint {
        let s = scale(side: side)
        return CGPoint(x: DrawnFont.sheet.minX + p.x / s, y: DrawnFont.sheet.maxY - p.y / s)
    }

    static func draw(in context: CGContext, side: CGFloat, glyph: CGPath?, guide: CGPath?, live: CGPath?, character: Character,
                     spacing: Int) {
        let sheet = DrawnFont.sheet
        let s = scale(side: side)
        context.saveGState()
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: side, height: side))
        context.scaleBy(x: s, y: s)
        context.translateBy(x: -sheet.minX, y: -sheet.minY)
        let hair = 1 / s

        // The guides
        func rule(_ y: CGFloat, alpha: CGFloat, width: CGFloat = 1, dash: Bool = false) {
            context.setStrokeColor(CGColor(srgbRed: 0.16, green: 0.22, blue: 0.40, alpha: alpha))
            context.setLineWidth(width * hair)
            context.setLineDash(phase: 0, lengths: dash ? [6 * hair, 5 * hair] : [])
            context.move(to: CGPoint(x: sheet.minX, y: y))
            context.addLine(to: CGPoint(x: sheet.maxX, y: y))
            context.strokePath()
        }
        rule(DrawnFont.capHeight, alpha: 0.35)
        rule(DrawnFont.xHeight, alpha: 0.3, dash: true)
        rule(0, alpha: 0.65, width: 1.5)
        rule(DrawnFont.descender, alpha: 0.3)
        context.setLineDash(phase: 0, lengths: [])

        // The character to draw over: the first version, faint, behind a second or third;
        // else the character printed, its capitals as tall as the cap height
        if let guide, !guide.isEmpty {
            context.setFillColor(CGColor(srgbRed: 0.16, green: 0.22, blue: 0.40, alpha: 0.13))
            context.addPath(guide)
            context.fillPath(using: .winding)
        } else {
            printMark(of: character, in: context)
        }

        // The ink
        context.setFillColor(CGColor(gray: 0, alpha: 1))
        for path in [glyph, live].compactMap({ $0 }) where !path.isEmpty {
            context.addPath(path)
            context.fillPath(using: .winding)
        }

        // Where the letter's room ends either side
        if let glyph, !glyph.isEmpty {
            let ink = glyph.boundingBoxOfPath
            context.setStrokeColor(CGColor(srgbRed: 0.878, green: 0.227, blue: 0.184, alpha: 0.45))
            context.setLineWidth(hair)
            context.setLineDash(phase: 0, lengths: [3 * hair, 4 * hair])
            for x in [ink.minX - CGFloat(spacing), ink.maxX + CGFloat(spacing)] {
                context.move(to: CGPoint(x: x, y: DrawnFont.descender - 60))
                context.addLine(to: CGPoint(x: x, y: DrawnFont.capHeight + 80))
            }
            context.strokePath()
        }
        context.restoreGState()
    }

    /// The character printed faintly in the plain face, on the baseline, centred.
    private static func printMark(of character: Character, in context: CGContext) {
        let unit = CTFontCreateWithName(markFace as CFString, 1000, nil)
        let size = 1000 * DrawnFont.capHeight / max(1, CTFontGetCapHeight(unit))
        let font = CTFontCreateWithName(markFace as CFString, size, nil)
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: String(character), attributes: [
            NSAttributedString.Key(kCTFontAttributeName as String): font,
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(srgbRed: 0.16, green: 0.22, blue: 0.40, alpha: 0.13),
        ]))
        let width = CTLineGetTypographicBounds(line, nil, nil, nil)
        context.textMatrix = .identity
        context.textPosition = CGPoint(x: 500 - width / 2, y: 0)
        CTLineDraw(line, context)
    }
}

/// What the pad's view keeps of a stroke while it is drawn: its points, and the pieces
/// they cover so far, grown as points come.
struct LiveGlyphStroke {
    var stroke: GlyphStroke
    let path = CGMutablePath()

    init(pen: GlyphPen, weight: CGFloat, first: GlyphPoint) {
        stroke = GlyphStroke(pen: pen, weight: weight, points: [first])
        GlyphOutline.addPieces(of: stroke, to: path)
    }

    /// Adds a point, unless it is where the last one was.
    mutating func add(_ point: GlyphPoint) {
        if let last = stroke.points.last, hypot(last.x - point.x, last.y - point.y) < 0.5 { return }
        stroke.points.append(point)
        GlyphOutline.addPieces(of: stroke, from: stroke.points.count - 1, to: path)
    }
}

/// The square pad a character is drawn on: a pen, a finger or the mouse draws a stroke,
/// which settles smoother when lifted and goes to `onStroke`. On the Mac the keyboard turns
/// to a character by typing it, and the arrows to the next and the one before.
struct GlyphPad: View {
    let glyph: DrawnGlyph?
    var guide: DrawnGlyph? = nil
    let character: Character
    let spacing: Int
    let pen: GlyphPen
    let weight: CGFloat
    let onStroke: (GlyphStroke) -> Void
    var onCharacter: (Character) -> Void = { _ in }
    var onStep: (Int) -> Void = { _ in }

    var body: some View {
        GlyphPadRepresentable(configuration: GlyphPadConfiguration(
            glyph: glyph, guide: guide, character: character, spacing: spacing, pen: pen, weight: weight,
            onStroke: onStroke, onCharacter: onCharacter, onStep: onStep))
            .aspectRatio(1, contentMode: .fit)
            .overlay(Rectangle().strokeBorder(Chrome.hairline))
            .accessibilityLabel("Drawing sheet for \(String(character))")
    }
}

struct GlyphPadConfiguration {
    var glyph: DrawnGlyph?
    var guide: DrawnGlyph?
    var character: Character
    var spacing: Int
    var pen: GlyphPen
    var weight: CGFloat
    var onStroke: (GlyphStroke) -> Void
    var onCharacter: (Character) -> Void
    var onStep: (Int) -> Void
}

/// The pad's state shared by both platforms' views: the glyph's pieces, kept until the
/// glyph changes, and the stroke being drawn.
final class GlyphPadState {
    var configuration: GlyphPadConfiguration? {
        didSet {
            if configuration?.glyph != oldValue?.glyph {
                glyphPath = configuration?.glyph.map(GlyphOutline.path(of:))
            }
            if configuration?.guide != oldValue?.guide {
                guidePath = configuration?.guide.map(GlyphOutline.path(of:))
            }
        }
    }
    private(set) var glyphPath: CGPath?
    private(set) var guidePath: CGPath?
    var live: LiveGlyphStroke?
    /// Whether a pen is down: the stroke it draws is kept whatever the view is told meanwhile.
    private(set) var isDrawing = false

    /// The configuration from SwiftUI. When the glyph or character changed, the stroke
    /// shown since the pen lifted has reached the font, or belongs to another character,
    /// and goes; a stroke still being drawn stays.
    func update(_ new: GlyphPadConfiguration) {
        let changed = configuration?.glyph != new.glyph || configuration?.character != new.character
            || configuration?.spacing != new.spacing || configuration?.guide != new.guide
        configuration = new
        if changed, !isDrawing { live = nil }
    }

    func begin(at point: CGPoint, pressure: CGFloat, side: CGFloat) {
        guard let configuration else { return }
        let p = GlyphSheetDrawing.fontPoint(point, side: side)
        live = LiveGlyphStroke(pen: configuration.pen, weight: configuration.weight,
                               first: GlyphPoint(x: p.x, y: p.y, pressure: pressure))
        isDrawing = true
    }

    func move(to point: CGPoint, pressure: CGFloat, side: CGFloat) {
        let p = GlyphSheetDrawing.fontPoint(point, side: side)
        live?.add(GlyphPoint(x: p.x, y: p.y, pressure: pressure))
    }

    /// The stroke, settled, to the font; the live one shown until the font has it.
    func end() {
        isDrawing = false
        guard let stroke = live?.stroke else { return }
        configuration?.onStroke(stroke.smoothed())
    }

    func cancel() {
        isDrawing = false
        live = nil
    }

    func draw(in context: CGContext, side: CGFloat) {
        guard let configuration else { return }
        GlyphSheetDrawing.draw(in: context, side: side, glyph: glyphPath, guide: guidePath, live: live?.path,
                               character: configuration.character, spacing: configuration.spacing)
    }
}

#if os(macOS)
struct GlyphPadRepresentable: NSViewRepresentable {
    let configuration: GlyphPadConfiguration

    func makeNSView(context: Context) -> GlyphPadView {
        let view = GlyphPadView()
        view.state.configuration = configuration
        return view
    }

    func updateNSView(_ view: GlyphPadView, context: Context) {
        view.state.update(configuration)
        view.needsDisplay = true
    }
}

final class GlyphPadView: NSView {
    let state = GlyphPadState()

    override var acceptsFirstResponder: Bool { true }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        window?.makeFirstResponder(self)
    }

    private var side: CGFloat { min(bounds.width, bounds.height) }

    /// From the top left, as the shared drawing counts.
    private func point(of event: NSEvent) -> CGPoint {
        let p = convert(event.locationInWindow, from: nil)
        return CGPoint(x: p.x, y: side - p.y)
    }

    /// A tablet's pressure; a mouse presses fully.
    private func pressure(of event: NSEvent) -> CGFloat {
        event.subtype == .tabletPoint ? CGFloat(event.pressure) : 1
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        state.begin(at: point(of: event), pressure: pressure(of: event), side: side)
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        state.move(to: point(of: event), pressure: pressure(of: event), side: side)
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        state.end()
        needsDisplay = true
    }

    override func keyDown(with event: NSEvent) {
        guard let configuration = state.configuration else { return super.keyDown(with: event) }
        switch event.keyCode {
        case 123: configuration.onStep(-1) // left arrow
        case 124: configuration.onStep(1)  // right arrow
        default:
            if event.modifierFlags.intersection([.command, .control, .option]).isEmpty,
               let typed = event.characters, typed.count == 1, let character = typed.first,
               !character.isWhitespace {
                configuration.onCharacter(character)
            } else {
                super.keyDown(with: event)
            }
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        state.draw(in: context, side: side)
    }
}
#else
struct GlyphPadRepresentable: UIViewRepresentable {
    let configuration: GlyphPadConfiguration

    func makeUIView(context: Context) -> GlyphPadView {
        let view = GlyphPadView()
        view.state.configuration = configuration
        return view
    }

    func updateUIView(_ view: GlyphPadView, context: Context) {
        view.state.update(configuration)
        view.setNeedsDisplay()
    }
}

final class GlyphPadView: UIView {
    let state = GlyphPadState()
    /// The touch drawing now.
    private var drawing: UITouch?
    /// Once a pencil has drawn here, fingers only rest on the screen.
    private var pencilSeen = false

    override init(frame: CGRect) {
        super.init(frame: frame)
        isMultipleTouchEnabled = true
        backgroundColor = .white
        contentMode = .redraw
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    private var side: CGFloat { min(bounds.width, bounds.height) }

    private func pressure(of touch: UITouch) -> CGFloat {
        guard touch.type == .pencil, touch.maximumPossibleForce > 0 else { return 1 }
        return min(1, touch.force / touch.maximumPossibleForce)
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard drawing == nil else { return }
        if touches.contains(where: { $0.type == .pencil }) { pencilSeen = true }
        guard let touch = touches.first(where: { $0.type == .pencil }) ?? (pencilSeen ? nil : touches.first) else { return }
        drawing = touch
        state.begin(at: touch.location(in: self), pressure: pressure(of: touch), side: side)
        setNeedsDisplay()
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard let touch = drawing, touches.contains(touch) else { return }
        for sample in event?.coalescedTouches(for: touch) ?? [touch] {
            state.move(to: sample.location(in: self), pressure: pressure(of: sample), side: side)
        }
        setNeedsDisplay()
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard let touch = drawing, touches.contains(touch) else { return }
        drawing = nil
        state.move(to: touch.location(in: self), pressure: pressure(of: touch), side: side)
        state.end()
        setNeedsDisplay()
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard let touch = drawing, touches.contains(touch) else { return }
        drawing = nil
        state.cancel()
        setNeedsDisplay()
    }

    override func draw(_ rect: CGRect) {
        guard let context = UIGraphicsGetCurrentContext() else { return }
        // The shared drawing's y runs up
        context.translateBy(x: 0, y: side)
        context.scaleBy(x: 1, y: -1)
        state.draw(in: context, side: side)
    }
}
#endif
