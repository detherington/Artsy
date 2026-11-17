import CoreGraphics
import Foundation

/// Speed lines or focus lines, the comic effects drawn as many tapered lines, laid out
/// round a clear area (the subject) before they are made into a layer of their own.
/// Focus lines run in from the canvas's edges and stop at the clear area; speed lines run
/// side by side along its long axis and stop at it. Every line comes from `seed`, so the
/// preview and the layer are the same lines. Canvas pixels, y up.
public struct ComicLines: Equatable {
    public enum Kind: String, CaseIterable, Identifiable {
        case focus
        case speed

        public var id: String { rawValue }
        /// What the layer they make is called.
        public var layerName: String { self == .focus ? "Focus lines" : "Speed lines" }
    }

    public var kind: Kind
    /// The subject's ellipse: focus lines run in to its edge; speed lines run along its
    /// long axis and, keeping it clear, stop at it.
    public var clear: EllipseGuide
    /// How many lines.
    public var count: Int
    /// How wide the widest line is, in canvas pixels.
    public var width: CGFloat
    /// How much one line differs from the next in length, width and spacing: 0 to 1.
    public var variety: CGFloat
    /// Speed lines: whether they stop at the clear area or run through it.
    public var keepsClear = true
    public var seed: UInt64

    public init(kind: Kind, clear: EllipseGuide, count: Int, width: CGFloat, variety: CGFloat = 0.5, seed: UInt64 = 1) {
        self.kind = kind
        self.clear = clear
        self.count = count
        self.width = width
        self.variety = variety
        self.seed = seed
    }

    /// Lines of `kind` round `clear` on a canvas of `canvasSize`, at the counts and widths
    /// that suit one: focus lines a little bolder and more of them.
    public static func laidOut(kind: Kind, clear: EllipseGuide, canvasSize: CGSize) -> ComicLines {
        let short = min(canvasSize.width, canvasSize.height)
        return ComicLines(kind: kind, clear: clear, count: kind == .focus ? 120 : 80,
                          width: (short * (kind == .focus ? 0.006 : 0.005)).rounded(.up))
    }

    /// The counts `stepCount` steps between.
    public static let counts = 20...400
    public static let countStep = 20

    public mutating func stepCount(by steps: Int) {
        let stepped = ((count + Self.countStep / 2) / Self.countStep + steps) * Self.countStep
        count = min(max(stepped, Self.counts.lowerBound), Self.counts.upperBound)
    }

    /// Wider or narrower by a quarter, `steps` times; never under a pixel.
    public mutating func stepWidth(by steps: Int) {
        width = max(width * pow(1.25, CGFloat(steps)), 1)
    }

    /// Variety by a tenth, `steps` times, kept within 0 to 1.
    public mutating func stepVariety(by steps: Int) {
        variety = min(max(((variety * 10).rounded() + CGFloat(steps)) / 10, 0), 1)
    }

    /// The same settings dealt again.
    public mutating func shuffle() {
        var random = SplitMix64(seed: seed)
        seed = random.next()
    }

    // MARK: - The lines

    /// One line: a wedge from its wide `start` to a point at `end` (a focus line), or a
    /// spindle pointed at both and widest midway (a speed line).
    public struct Line: Equatable {
        public var start: CGPoint
        public var end: CGPoint
        public var width: CGFloat
        /// Pointed at both ends, not only at `end`.
        public var isSpindle: Bool

        /// Its outline, in canvas pixels.
        public var path: CGPath {
            let path = CGMutablePath()
            let length = hypot(end.x - start.x, end.y - start.y)
            guard length > 1e-6 else { return path }
            let half = CGVector(dx: -(end.y - start.y) / length * width / 2, dy: (end.x - start.x) / length * width / 2)
            if isSpindle {
                // Two curves whose middles are half the width out: widest midway, pointed at the ends
                let mid = CGPoint(x: (start.x + end.x) / 2, y: (start.y + end.y) / 2)
                path.move(to: start)
                path.addQuadCurve(to: end, control: CGPoint(x: mid.x + 2 * half.dx, y: mid.y + 2 * half.dy))
                path.addQuadCurve(to: start, control: CGPoint(x: mid.x - 2 * half.dx, y: mid.y - 2 * half.dy))
            } else {
                path.move(to: CGPoint(x: start.x + half.dx, y: start.y + half.dy))
                path.addLine(to: end)
                path.addLine(to: CGPoint(x: start.x - half.dx, y: start.y - half.dy))
            }
            path.closeSubpath()
            return path
        }
    }

    /// The lines on a canvas of `canvasSize`.
    public func lines(canvasSize: CGSize) -> [Line] {
        let canvas = CGRect(origin: .zero, size: canvasSize)
        guard !canvas.isEmpty, count > 0, width > 0, min(clear.radii.width, clear.radii.height) > 0 else { return [] }
        var random = SplitMix64(seed: seed)
        return kind == .focus ? focusLines(in: canvas, random: &random) : speedLines(in: canvas, random: &random)
    }

    private func focusLines(in canvas: CGRect, random: inout SplitMix64) -> [Line] {
        let c = clear.centre
        var lines: [Line] = []
        for i in 0..<count {
            // Four draws a line, used or not, so one line's fate leaves the next alone
            let jitter = random.unit(), push = random.unit(), thin = random.unit()
            _ = random.unit()
            let angle = 2 * .pi * (CGFloat(i) + 0.5 + (jitter - 0.5) * variety * 0.9) / CGFloat(count)
            let d = CGVector(dx: cos(angle), dy: sin(angle))
            // Where the ray from the centre meets the clear area's edge
            let local = clear.local(CGPoint(x: c.x + d.dx, y: c.y + d.dy))
            let a = clear.radii.width, b = clear.radii.height
            let edge = 1 / sqrt((local.x / a) * (local.x / a) + (local.y / b) * (local.y / b))
            guard let exit = Self.exit(from: c, along: d, of: canvas) else { continue }
            // Pulled back toward the canvas's edge by up to 60% of the run with full variety,
            // most of them a little and a few a long way, as inked ones are
            let inner = edge + max(exit - edge, 0) * 0.6 * variety * push * push
            let w = width * (1 - variety * 0.7 * thin)
            let outer = exit + w
            guard outer > inner + w else { continue }
            lines.append(Line(start: CGPoint(x: c.x + d.dx * outer, y: c.y + d.dy * outer),
                              end: CGPoint(x: c.x + d.dx * inner, y: c.y + d.dy * inner), width: w, isSpindle: false))
        }
        return lines
    }

    private func speedLines(in canvas: CGRect, random: inout SplitMix64) -> [Line] {
        let v = CGVector(dx: cos(clear.rotation), dy: sin(clear.rotation))
        let n = CGVector(dx: -v.dy, dy: v.dx)
        let o = CGPoint(x: canvas.midX, y: canvas.midY)
        let corners = [CGPoint(x: canvas.minX, y: canvas.minY), CGPoint(x: canvas.maxX, y: canvas.minY),
                       CGPoint(x: canvas.minX, y: canvas.maxY), CGPoint(x: canvas.maxX, y: canvas.maxY)]
        let along = corners.map { ($0.x - o.x) * v.dx + ($0.y - o.y) * v.dy }
        let across = corners.map { ($0.x - o.x) * n.dx + ($0.y - o.y) * n.dy }
        let aMin = along.min()!, span = along.max()! - aMin
        let nMin = across.min()!, nSpan = across.max()! - nMin
        var lines: [Line] = []
        for i in 0..<count {
            let jitter = random.unit(), short = random.unit(), place = random.unit(), thin = random.unit()
            let off = nMin + nSpan * (CGFloat(i) + 0.5 + (jitter - 0.5) * variety) / CGFloat(count)
            let length = span * (1 - 0.65 * variety * short)
            // Anywhere along, running a little off either end now and then
            let from = aMin - 0.1 * span + (1.2 * span - length) * place
            let w = width * (1 - variety * 0.7 * thin)
            func point(_ a: CGFloat) -> CGPoint {
                CGPoint(x: o.x + v.dx * a + n.dx * off, y: o.y + v.dy * a + n.dy * off)
            }
            var parts = [(from, from + length)]
            if keepsClear, let cross = crossing(from: point(from), along: v) {
                // The clear area spans `from + cross.enter` to `from + cross.leave` along the line
                parts = [(from, min(from + length, from + cross.enter)), (max(from, from + cross.leave), from + length)]
            }
            for (a, b) in parts where b - a >= 3 * w {
                lines.append(Line(start: point(a), end: point(b), width: w, isSpindle: true))
            }
        }
        return lines
    }

    /// Where the line from `p` along the unit vector `v` enters and leaves the clear area,
    /// as distances along it (either may be behind `p`); none if it misses.
    private func crossing(from p: CGPoint, along v: CGVector) -> (enter: CGFloat, leave: CGFloat)? {
        let q = clear.local(p)
        let lv = clear.local(CGPoint(x: clear.centre.x + v.dx, y: clear.centre.y + v.dy))
        let a = clear.radii.width, b = clear.radii.height
        // ((q.x + t·lv.x) / a)² + ((q.y + t·lv.y) / b)² = 1
        let A = (lv.x / a) * (lv.x / a) + (lv.y / b) * (lv.y / b)
        let B = 2 * (q.x * lv.x / (a * a) + q.y * lv.y / (b * b))
        let C = (q.x / a) * (q.x / a) + (q.y / b) * (q.y / b) - 1
        let disc = B * B - 4 * A * C
        guard A > 0, disc > 0 else { return nil }
        let root = sqrt(disc)
        return ((-B - root) / (2 * A), (-B + root) / (2 * A))
    }

    /// How far along the ray from `p` along unit `d` it leaves `rect`; none if it never
    /// crosses it going forward.
    static func exit(from p: CGPoint, along d: CGVector, of rect: CGRect) -> CGFloat? {
        var t0 = -CGFloat.infinity, t1 = CGFloat.infinity
        for (origin, direction, low, high) in [(p.x, d.dx, rect.minX, rect.maxX), (p.y, d.dy, rect.minY, rect.maxY)] {
            if abs(direction) < 1e-12 {
                if origin < low || origin > high { return nil }
            } else {
                let a = (low - origin) / direction, b = (high - origin) / direction
                t0 = max(t0, min(a, b))
                t1 = min(t1, max(a, b))
            }
        }
        guard t1 > max(t0, 0) else { return nil }
        return t1
    }

    // MARK: - Making them

    /// The lines filled in `colour` (Display P3, as layers are) on a clear image of
    /// `canvasSize`, inside `clip` if there is one.
    public func image(canvasSize: CGSize, colour: StrokeColor, clip: CGPath? = nil) -> CGImage? {
        let width = Int(canvasSize.width), height = Int(canvasSize.height)
        guard width > 0, height > 0, let space = CGColorSpace(name: CGColorSpace.displayP3),
              let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                      space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        // Canvas pixels run y up, as the context does
        if let clip {
            context.addPath(clip)
            context.clip()
        }
        let components = [colour.red, colour.green, colour.blue, colour.alpha].map { CGFloat($0) }
        context.setFillColor(CGColor(colorSpace: space, components: components) ?? CGColor(gray: 0, alpha: 1))
        for line in lines(canvasSize: canvasSize) { context.addPath(line.path) }
        context.fillPath()
        return context.makeImage()
    }

    public enum Failure: LocalizedError {
        case noCanvas
        case couldNotDraw
        public var errorDescription: String? {
            switch self {
            case .noCanvas: return "There is no canvas to add the lines to"
            case .couldNotDraw: return "The lines could not be drawn"
            }
        }
    }

    /// The lines as a new layer, named for their kind, above the current one, in `colour`
    /// and inside `clip` if there is one: one step to undo.
    @discardableResult
    public func addLayer(to viewModel: CanvasViewModel, renderer: CanvasRenderer, colour: StrokeColor,
                         clip: CGPath?) throws -> Layer {
        guard let stack = viewModel.layerStack else { throw Failure.noCanvas }
        guard let image = image(canvasSize: viewModel.canvasSize, colour: colour, clip: clip) else { throw Failure.couldNotDraw }
        // Adding a layer is a step to undo; nothing already there changes
        viewModel.saveUndoSnapshot(renderer: renderer, description: "Add \(kind.layerName)", changing: .nothing)
        let step = viewModel.undoManager.lastStepToken
        do {
            let index = try stack.addLayer(above: stack.activeLayerIndex, name: kind.layerName)
            let layer = stack.layers[index]
            try renderer.fillLayerFitToCanvas(with: image, layer: layer)
            renderer.updateThumbnail(for: layer)
            viewModel.markDirty()
            return layer
        } catch {
            viewModel.undoManager.popLastSnapshot(if: step)
            throw error
        }
    }
}

/// A small random generator that deals the same numbers from the same seed on every
/// device and every run (SplitMix64).
struct SplitMix64 {
    private var state: UInt64

    init(seed: UInt64) { state = seed }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }

    /// A number from 0 up to 1.
    mutating func unit() -> CGFloat {
        CGFloat(next() >> 11) / CGFloat(1 << 53)
    }
}
