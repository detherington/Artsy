import XCTest
import CoreGraphics
#if canImport(Artsy)
@testable import Artsy
#endif
@testable import ArtsyEngine

/// Balloon looks: each kind's shapes, the lines, fills, tails and margins; saved with the balloon,
/// kept per kind for the next one, and changed as steps to undo.
final class BalloonLookTests: XCTestCase {
    private let sentence = "Hello there, how are you today? Fine, I hope."
    private let id = UUID(uuidString: "11111111-2222-3333-4444-555555555555")!
    private let tip = CGPoint(x: 420, y: 300)

    private func balloon(_ style: BalloonStyle, _ look: BalloonLook = BalloonLook(),
                         tail: CGPoint? = CGPoint(x: 420, y: 300), wrap: CGFloat = 200) -> Balloon {
        var balloon = Balloon(style: style, center: CGPoint(x: 500, y: 500), text: sentence, wrapWidth: wrap, face: .dialogue,
                              fontSize: 20, allCaps: true, tail: style.hasTail ? tail : nil, look: look)
        balloon.id = id
        return balloon
    }

    private func corners(_ r: CGRect) -> [CGPoint] {
        [CGPoint(x: r.minX, y: r.minY), CGPoint(x: r.maxX, y: r.minY), CGPoint(x: r.minX, y: r.maxY), CGPoint(x: r.maxX, y: r.maxY)]
    }

    /// The points along `path`, flattened.
    private func points(of path: CGPath) -> [CGPoint] {
        var points: [CGPoint] = []
        path.flattened(threshold: 0.25).applyWithBlock { e in
            if e.pointee.type == .moveToPoint || e.pointee.type == .addLineToPoint { points.append(e.pointee.points[0]) }
        }
        return points
    }

    /// A path's elements counted, its points summed and its box: equal only for the same outline.
    private func signature(_ path: CGPath) -> String {
        var count = 0
        var sum: Double = 0
        path.applyWithBlock { e in
            let n: Int
            switch e.pointee.type {
            case .moveToPoint, .addLineToPoint: n = 1
            case .addQuadCurveToPoint: n = 2
            case .addCurveToPoint: n = 3
            default: n = 0
            }
            count += 1
            for i in 0..<n { sum += Double(e.pointee.points[i].x) + 2 * Double(e.pointee.points[i].y) }
        }
        let box = path.boundingBoxOfPath
        return String(format: "%d %.3f %.2f %.2f %.2f %.2f", count, sum, box.minX, box.minY, box.width, box.height)
    }

    // MARK: - Shapes

    /// The plain look draws every kind exactly as balloons were drawn before there were looks
    /// (the outlines measured on main at dce006a), so nothing already lettered moves; naming
    /// the kind's own shape and tail is the same as naming none.
    func testThePlainLookDrawsAsBalloonsAlwaysHave() {
        let before: [String: String] = [
            "speech 420": "9 30543.009 362.06 300.00 275.88 267.98",
            "speech 640": "9 35807.579 362.06 432.02 277.94 287.98",
            "thought 420": "36 118926.993 353.40 325.72 291.56 262.87",
            "thought 640": "36 146780.558 353.40 404.67 291.56 263.53",
            "shout 420": "38 55070.145 328.95 300.00 342.09 283.01",
            "shout 640": "38 56108.846 328.95 416.99 342.09 303.01",
            "caption 420": "5 6000.000 395.50 448.50 209.00 103.00",
            "caption 640": "5 6000.000 395.50 448.50 209.00 103.00",
        ]
        for style in [BalloonStyle.speech, .thought, .shout, .caption] {
            for tip in [CGPoint(x: 420, y: 300), CGPoint(x: 640, y: 720)] {
                let plain = BalloonLayout(balloon(style, tail: tip))
                XCTAssertEqual(signature(plain.body), before["\(style.rawValue) \(Int(tip.x))"], "\(style) toward \(tip)")
                let named = BalloonLook(shape: style.shapes.first, tail: style.hasTail ? style.ownTail : nil)
                XCTAssertEqual(BalloonLayout(balloon(style, named, tail: tip)).body, plain.body, "\(style)'s own, named")
            }
        }
    }

    /// Every kind's every shape, in every line, holds its words, wide or in a tall narrow
    /// block, is picked up at its middle and is drawn within its bounds; a kind's shapes are
    /// each their own.
    func testEveryShapeHoldsItsWords() {
        for style in BalloonStyle.allCases where style != .sound {
            var outlines: [BalloonShape: CGPath] = [:]
            for shape in style.shapes {
                for line in BalloonLine.allCases {
                  for wrap: CGFloat in [200, 90] {
                    let layout = BalloonLayout(balloon(style, BalloonLook(shape: shape, line: line), tail: nil, wrap: wrap))
                    for corner in corners(layout.textBox.insetBy(dx: 1, dy: 1)) {
                        XCTAssertTrue(layout.body.contains(corner), "\(shape) \(style), \(line) line, \(wrap) wide, holds \(corner)")
                    }
                    XCTAssertTrue(layout.contains(CGPoint(x: 500, y: 500)), "\(shape) \(style) is picked up at its middle")
                    XCTAssertTrue(layout.bounds.contains(layout.body.boundingBoxOfPath), "\(shape) \(style) within its bounds")
                    if line == .solid, wrap == 200 { outlines[shape] = layout.body }
                  }
                }
            }
            for a in style.shapes {
                for b in style.shapes where a.rawValue < b.rawValue {
                    XCTAssertNotEqual(outlines[a], outlines[b], "\(style): \(a) and \(b) differ")
                }
            }
        }
    }

    /// A shape the kind does not offer reads as the kind's own, and a sound effect has none.
    func testAShapeIsItsKindsOrTheKindsOwn() {
        XCTAssertEqual(balloon(.caption, BalloonLook(shape: .cloud)).shape, .box)
        XCTAssertEqual(BalloonLayout(balloon(.caption, BalloonLook(shape: .cloud))).body, BalloonLayout(balloon(.caption)).body)
        XCTAssertEqual(balloon(.thought, BalloonLook(shape: .oval)).shape, .oval, "a thought may be an oval")
        XCTAssertEqual(balloon(.speech, BalloonLook(shape: .rounded)).shape, .rounded)
        XCTAssertNil(balloon(.sound, BalloonLook(shape: .box)).shape)
        XCTAssertTrue(BalloonLayout(balloon(.sound, BalloonLook(shape: .box, fill: .black))).body.isEmpty)
    }

    /// The irregular shapes are each balloon's own: the same every time it is drawn, another
    /// balloon another outline.
    func testIrregularShapesAreTheirBalloonsOwn() {
        for (style, shape) in [(BalloonStyle.speech, BalloonShape.wobbly), (.thought, .puffy), (.shout, .jagged), (.shout, .blast)] {
            let one = balloon(style, BalloonLook(shape: shape))
            var other = one
            other.id = UUID()
            XCTAssertEqual(BalloonLayout(one).body, BalloonLayout(one).body, "\(shape): the same every time")
            XCTAssertNotEqual(BalloonLayout(other).body, BalloonLayout(one).body, "\(shape): another balloon, another outline")
        }
    }

    // MARK: - Tails

    /// Every tail of every shape reaches its speaker and stops there: a wedge or lightning
    /// to its tip, bubbles toward it; a tip inside the body draws none.
    func testEveryTailReachesItsSpeaker() {
        let nearTip = CGPoint(x: tip.x + (500 - tip.x) * 0.04, y: tip.y + (500 - tip.y) * 0.04)
        let past = CGPoint(x: 410, y: 280)
        for style in BalloonStyle.allCases where style.hasTail {
            for shape in style.shapes {
                let tailless = BalloonLayout(balloon(style, BalloonLook(shape: shape), tail: nil)).body.boundingBoxOfPath
                for tail in BalloonTail.allCases {
                    let layout = BalloonLayout(balloon(style, BalloonLook(shape: shape, tail: tail)))
                    let name = "\(shape) \(style), \(tail) tail"
                    XCTAssertFalse(layout.body.contains(past), "\(name) stops at its tip")
                    XCTAssertTrue(layout.bounds.contains(layout.body.boundingBoxOfPath), name)
                    if tail == .bubbles {
                        let reach = layout.body.boundingBoxOfPath
                        XCTAssertLessThan(reach.minY, tailless.minY - 20, "\(name) trails toward the thinker")
                        XCTAssertGreaterThan(reach.minY, tip.y - 12, "\(name) not past them")
                    } else {
                        let closest = points(of: layout.body).map { hypot($0.x - tip.x, $0.y - tip.y) }.min() ?? .infinity
                        XCTAssertLessThan(closest, 1.5, "\(name) reaches its tip")
                        if tail != .lightning { XCTAssertTrue(layout.body.contains(nearTip), "\(name) to a point") }
                    }
                    let inside = BalloonLayout(balloon(style, BalloonLook(shape: shape, tail: tail), tail: CGPoint(x: 505, y: 500)))
                    XCTAssertEqual(inside.body.boundingBoxOfPath, tailless, "\(name): a tip inside draws no tail")
                }
            }
        }
    }

    /// Lightning steps aside on its way: its outline reaches well off the straight line from
    /// the body to the tip, as a wedge's does not.
    func testLightningZigzags() {
        func farthestOff(_ tail: BalloonTail) -> CGFloat {
            let body = BalloonLayout(balloon(.speech, BalloonLook(tail: tail))).body
            let foot = BalloonLayout(balloon(.speech, tail: nil)).body.boundingBoxOfPath.minY
            // Off the line from the middle to the tip, for the tail's points below the body
            let dx = tip.x - 500, dy = tip.y - 500, length = hypot(dx, dy)
            return points(of: body).filter { $0.y < foot - 2 }
                .map { abs(($0.x - 500) * dy - ($0.y - 500) * dx) / length }.max() ?? 0
        }
        XCTAssertGreaterThan(farthestOff(.lightning), farthestOff(.straight) + 5)
    }

    // MARK: - Roots and widths

    /// A tail's width scales it: past the body on the way to its tip, a wide tail is wider
    /// and a narrow one narrower; bubbles grow and shrink; the plain width is the tail as it was.
    func testATailsWidthScalesIt() throws {
        func across(_ width: CGFloat, _ tail: BalloonTail) -> CGFloat {
            let layout = BalloonLayout(balloon(.speech, BalloonLook(tail: tail, tailWidth: width)))
            // Two thirds of the way from the middle to the tip, square to the way there
            let at = CGPoint(x: 500 + (tip.x - 500) * 0.66, y: 500 + (tip.y - 500) * 0.66)
            let length = hypot(tip.x - 500, tip.y - 500)
            let n = CGPoint(x: -(tip.y - 500) / length, y: (tip.x - 500) / length)
            return CGFloat(stride(from: -80.0, through: 80.0, by: 0.25).filter { s in
                layout.body.contains(CGPoint(x: at.x + n.x * CGFloat(s), y: at.y + n.y * CGFloat(s)))
            }.count) * 0.25
        }
        for tail in [BalloonTail.curved, .straight] {
            let usual = across(1, tail)
            XCTAssertGreaterThan(usual, 4, "\(tail)")
            XCTAssertGreaterThan(across(2, tail), usual * 1.5, "\(tail): wider")
            XCTAssertLessThan(across(0.5, tail), usual * 0.7, "\(tail): narrower")
        }
        // Lightning steps aside, so its band is measured as all it covers past the body
        func covered(_ width: CGFloat) -> Int {
            let layout = BalloonLayout(balloon(.speech, BalloonLook(tail: .lightning, tailWidth: width)))
            let plain = BalloonLayout(balloon(.speech, tail: nil)).body
            var count = 0
            for x in stride(from: 380, to: 560, by: 2) {
                for y in stride(from: 290, to: 500, by: 2) {
                    let p = CGPoint(x: x, y: y)
                    if layout.body.contains(p), !plain.contains(p) { count += 1 }
                }
            }
            return count
        }
        XCTAssertGreaterThan(Double(covered(2)), Double(covered(1)) * 1.4, "lightning: wider")
        XCTAssertLessThan(Double(covered(0.5)), Double(covered(1)) * 0.75, "lightning: narrower")

        let small = BalloonLayout(balloon(.thought, BalloonLook(tailWidth: 0.6))).body.boundingBoxOfPath
        let large = BalloonLayout(balloon(.thought, BalloonLook(tailWidth: 1.3))).body.boundingBoxOfPath
        XCTAssertNotEqual(small, large, "bubbles of another size")
        XCTAssertEqual(BalloonLayout(balloon(.thought, BalloonLook(tailWidth: 1))).body, BalloonLayout(balloon(.thought)).body)
    }

    /// A tail's base set by width keeps it however wide the balloon is, where one in
    /// proportion to the body grows with it; its ends sit inside the body, square to the way
    /// to the tip, and the tail still reaches its tip. Bubbles have no base.
    func testATailsBaseKeepsItsWidth() throws {
        func layout(wrap: CGFloat, base: CGFloat?, tail: BalloonTail = .straight, text: String? = nil) -> BalloonLayout {
            var b = balloon(.speech, BalloonLook(tail: tail, tailBase: base), wrap: wrap)
            if let text { b.text = text }
            return BalloonLayout(b)
        }
        let narrowAuto = try XCTUnwrap(layout(wrap: 90, base: nil).baseWidth)
        let wideAuto = try XCTUnwrap(layout(wrap: 300, base: nil).baseWidth)
        XCTAssertGreaterThan(wideAuto, narrowAuto * 1.3, "in proportion, a wider balloon has a wider base")

        for wrap: CGFloat in [90, 200, 300] {
            for tail in [BalloonTail.curved, .straight, .lightning] {
                let l = layout(wrap: wrap, base: 2, tail: tail)
                let name = "\(tail), \(wrap) wide"
                XCTAssertEqual(try XCTUnwrap(l.baseWidth), 40, accuracy: 0.01, "\(name): two sizes of 20")
                let ends = try XCTUnwrap(l.base)
                let plain = BalloonLayout({ var b = l.balloon; b.tail = nil; return b }()).body
                XCTAssertTrue(plain.contains(ends.left) && plain.contains(ends.right), "\(name): its ends inside the body")
                let middle = CGPoint(x: (ends.left.x + ends.right.x) / 2, y: (ends.left.y + ends.right.y) / 2)
                let square = (ends.left.x - ends.right.x) * (tip.x - middle.x) + (ends.left.y - ends.right.y) * (tip.y - middle.y)
                XCTAssertEqual(square / (40 * hypot(tip.x - middle.x, tip.y - middle.y)), 0, accuracy: 1e-6, "\(name): square to the tip")
                let closest = points(of: l.body).map { hypot($0.x - tip.x, $0.y - tip.y) }.min() ?? .infinity
                XCTAssertLessThan(closest, 1.5, "\(name): reaching its tip")
                XCTAssertTrue(l.bounds.contains(l.body.boundingBoxOfPath), name)
            }
        }

        // Wider than a short balloon is across: kept inside it
        let short = layout(wrap: 200, base: 8, text: "Hi!")
        let ends = try XCTUnwrap(short.base)
        let plain = BalloonLayout({ var b = short.balloon; b.tail = nil; return b }()).body
        XCTAssertTrue(plain.contains(ends.left) && plain.contains(ends.right))
        XCTAssertLessThan(try XCTUnwrap(short.baseWidth), 160)

        XCTAssertNil(BalloonLayout(balloon(.thought, BalloonLook(tailBase: 2))).base, "bubbles have no base")
        XCTAssertNil(BalloonLayout(balloon(.speech, BalloonLook(tailBase: 2), tail: nil)).baseHandle, "nor does no tail")

        // An end dragged out: twice its distance from the middle, along the base
        let set = layout(wrap: 200, base: 2)
        let e = try XCTUnwrap(set.base)
        let middle = CGPoint(x: (e.left.x + e.right.x) / 2, y: (e.left.y + e.right.y) / 2)
        let along = CGPoint(x: (e.left.x - e.right.x) / 40, y: (e.left.y - e.right.y) / 40)
        XCTAssertEqual(set.baseHandle, e.left)
        XCTAssertEqual(try XCTUnwrap(set.baseSize(draggedTo: CGPoint(x: middle.x + along.x * 30, y: middle.y + along.y * 30))), 3,
                       accuracy: 1e-6)
        XCTAssertEqual(try XCTUnwrap(set.baseSize(draggedTo: CGPoint(x: middle.x + along.x * 900, y: middle.y + along.y * 900))),
                       BalloonLook.tailBases.upperBound, "no wider than the widest")
    }

    // MARK: - Lines and fills

    /// Dashed, double, heavy and no line are only how the outline is stroked; heavy is twice
    /// as wide and double reaches further. Wavy and electric move the outline in and out.
    func testTheLinesInkTheOutline() {
        let solid = BalloonLayout(balloon(.speech))
        for line in [BalloonLine.heavy, .dashed, .double, .none] {
            XCTAssertEqual(BalloonLayout(balloon(.speech, BalloonLook(line: line))).body, solid.body, "\(line) keeps the outline")
        }
        XCTAssertEqual(BalloonLayout(balloon(.speech, BalloonLook(line: .heavy))).lineWidth, solid.lineWidth * 2)
        let double = BalloonLayout(balloon(.speech, BalloonLook(line: .double)))
        XCTAssertTrue(double.bounds.contains(solid.bounds))
        XCTAssertGreaterThan(double.bounds.width, solid.bounds.width)

        for style in [BalloonStyle.speech, .caption] {
            let plain = BalloonLayout(balloon(style, tail: nil)).body
            for line in [BalloonLine.wavy, .electric] {
                let moved = points(of: BalloonLayout(balloon(style, BalloonLook(line: line), tail: nil)).body)
                let outside = moved.filter { !plain.contains($0) }.count
                XCTAssertGreaterThan(outside, moved.count / 5, "\(style), \(line): out")
                XCTAssertGreaterThan(moved.count - outside, moved.count / 5, "\(style), \(line): and in")
            }
        }
    }

    /// `layout` drawn at one to one, and a pixel's colour read back (0–255, y up).
    private func render(_ layout: BalloonLayout) throws -> (CGPoint) -> (r: Int, g: Int, b: Int, a: Int) {
        let width = 1000, height = 1000
        let space = try XCTUnwrap(CGColorSpace(name: CGColorSpace.sRGB))
        let context = try XCTUnwrap(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                              space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        layout.draw(in: context)
        let data = try XCTUnwrap(context.data).assumingMemoryBound(to: UInt8.self)
        // The reader keeps the context, whose memory the pixels are
        return { p in
            withExtendedLifetime(context) {
                let i = ((height - 1 - Int(p.y)) * width + Int(p.x)) * 4
                return (Int(data[i]), Int(data[i + 1]), Int(data[i + 2]), Int(data[i + 3]))
            }
        }
    }

    /// Each fill fills the body; the words are black, or white in a black balloon. A dashed
    /// line has gaps along it; no line leaves the fill to the edge.
    func testFillsAndLinesAreDrawn() throws {
        for fill in BalloonFill.allCases {
            let layout = BalloonLayout(balloon(.caption, BalloonLook(fill: fill), tail: nil))
            let pixel = try render(layout)
            let box = layout.body.boundingBoxOfPath
            let inside = pixel(CGPoint(x: box.minX + 6, y: box.midY))
            let components = try XCTUnwrap(fill.color.converted(to: try XCTUnwrap(CGColorSpace(name: CGColorSpace.sRGB)),
                                                                intent: .defaultIntent, options: nil)?.components)
            let expected = components.count >= 3 ? components.prefix(3).map { Int(($0 * 255).rounded()) }
                                                  : Array(repeating: Int((components[0] * 255).rounded()), count: 3)
            XCTAssertEqual(inside.r, expected[0], accuracy: 2, "\(fill)")
            XCTAssertEqual(inside.g, expected[1], accuracy: 2, "\(fill)")
            XCTAssertEqual(inside.b, expected[2], accuracy: 2, "\(fill)")
            // The words' darkest and lightest within their box
            var lightest = 0, darkest = 255
            for x in stride(from: Int(layout.textBox.minX), to: Int(layout.textBox.maxX), by: 1) {
                for y in stride(from: Int(layout.textBox.minY), to: Int(layout.textBox.maxY), by: 2) {
                    let p = pixel(CGPoint(x: x, y: y))
                    lightest = max(lightest, p.r)
                    darkest = min(darkest, p.r)
                }
            }
            if fill == .black {
                XCTAssertGreaterThan(lightest, 230, "white words in a black balloon")
            } else {
                XCTAssertLessThan(darkest, 25, "black words in a \(fill) one")
            }
        }

        func outlineInk(_ line: BalloonLine) throws -> (dark: Int, light: Int) {
            let layout = BalloonLayout(balloon(.speech, BalloonLook(line: line), tail: nil))
            let pixel = try render(layout)
            let box = layout.body.boundingBoxOfPath
            var dark = 0, light = 0
            for i in 0..<720 {
                // Round the oval just inside its outline, the opaque pixels only
                let t = CGFloat(i) / 720 * 2 * .pi
                let c = pixel(CGPoint(x: box.midX + (box.width / 2 - 0.3) * cos(t), y: box.midY + (box.height / 2 - 0.3) * sin(t)))
                guard c.a > 200 else { continue }
                if c.r < 80 { dark += 1 } else if c.r > 200 { light += 1 }
            }
            return (dark, light)
        }
        let solid = try outlineInk(.solid), dashed = try outlineInk(.dashed), none = try outlineInk(.none)
        XCTAssertEqual(solid.light, 0, "a solid line all along")
        XCTAssertGreaterThan(dashed.light, solid.dark / 12, "a dashed line has gaps")
        XCTAssertGreaterThan(dashed.dark, solid.dark / 3, "and dashes")
        XCTAssertEqual(none.dark, 0, "no line")
    }

    /// The panel's pictures: one of every kind's every shape, line and tail, drawn into the
    /// size asked, with something in it.
    func testThePanelsPictures() throws {
        for style in BalloonStyle.allCases where style != .sound {
            for shape in style.shapes {
                for line in BalloonLine.allCases {
                    let image = try XCTUnwrap(BalloonLayout.preview(style, look: BalloonLook(shape: shape, line: line), tail: style.hasTail,
                                                                    width: 60, height: 44), "\(shape) \(style)")
                    XCTAssertEqual(image.width, 60)
                    XCTAssertEqual(image.height, 44)
                    let data = try XCTUnwrap(image.dataProvider?.data as Data?)
                    XCTAssertGreaterThan(stride(from: 3, to: data.count, by: 4).filter { data[$0] > 0 }.count, 300, "\(shape) \(style) drawn")
                }
            }
        }
        XCTAssertNil(BalloonLayout.preview(.sound, look: BalloonLook(), tail: false, width: 60, height: 44))
    }

    // MARK: - The margin

    /// The margin is the room between the words and the body's edge, that many times the
    /// usual: a box's own margin round the words, an oval's room past them; the usual draws
    /// as balloons always have, and more room makes every shape larger.
    func testTheMarginIsTheRoomRoundTheWords() {
        for style in [BalloonStyle.speech, .thought, .shout, .caption] {
            XCTAssertEqual(BalloonLayout(balloon(style, BalloonLook(margin: 1))).body, BalloonLayout(balloon(style)).body,
                           "\(style): the usual margin is the plain look")
        }
        // A caption's box is the words' with the margin round it: half the size across, four
        // tenths up and down, at 20 px lettering
        let words = BalloonLayout(balloon(.caption)).textBox
        for margin: CGFloat in [0.5, 2, 4] {
            let layout = BalloonLayout(balloon(.caption, BalloonLook(margin: margin)))
            XCTAssertEqual(layout.margin, margin, "\(margin): drawn as set")
            let box = layout.body.boundingBoxOfPath
            XCTAssertEqual(box.width, words.width + 20 * margin, accuracy: 0.01, "\(margin) across")
            XCTAssertEqual(box.height, words.height + 16 * margin, accuracy: 0.01, "\(margin) up and down")
        }
        // An oval's room past its words, twice and four times over
        func room(_ margin: CGFloat) -> CGSize {
            let layout = BalloonLayout(balloon(.speech, BalloonLook(margin: margin), tail: nil))
            let body = layout.body.boundingBoxOfPath
            return CGSize(width: body.width - layout.textBox.width, height: body.height - layout.textBox.height)
        }
        for margin: CGFloat in [2, 4] {
            XCTAssertEqual(room(margin).width, room(1).width * margin, accuracy: 0.01, "an oval's room across, \(margin) times")
            XCTAssertEqual(room(margin).height, room(1).height * margin, accuracy: 0.01, "and up and down")
        }
        // Every shape: tighter with less, larger with more
        for style in [BalloonStyle.speech, .thought, .shout, .caption] {
            for shape in style.shapes {
                func size(_ margin: CGFloat) -> CGSize {
                    BalloonLayout(balloon(style, BalloonLook(shape: shape, margin: margin), tail: nil)).body.boundingBoxOfPath.size
                }
                let tight = size(0), usual = size(1), roomy = size(4)
                XCTAssertLessThan(tight.width * tight.height, usual.width * usual.height * 0.97, "\(shape) \(style): tighter")
                XCTAssertGreaterThan(roomy.width, usual.width + 40, "\(shape) \(style): wider with more room")
                XCTAssertGreaterThan(roomy.height, usual.height + 30, "\(shape) \(style): taller with more room")
            }
        }
    }

    /// However tight the margin, every shape in every line still holds its words: all along
    /// each line's ink, wide, in a tall narrow block or in one long line. Where the margin is
    /// tighter than the shape can go round them, it is drawn as tight as it can, never past
    /// the usual; an oval can still go well inside its usual size.
    func testATightMarginStillHoldsItsWords() {
        for style in BalloonStyle.allCases where style != .sound {
            for shape in style.shapes {
                for line in BalloonLine.allCases {
                    for wrap: CGFloat in [200, 90, 600] {
                        for margin: CGFloat in [0, 0.25, 0.5] {
                            let layout = BalloonLayout(balloon(style, BalloonLook(shape: shape, line: line, margin: margin),
                                                               tail: nil, wrap: wrap))
                            let named = "\(shape) \(style), \(line) line, \(wrap) wide, margin \(margin)"
                            XCTAssertGreaterThanOrEqual(layout.margin, margin, named)
                            XCTAssertLessThanOrEqual(layout.margin, 1, named)
                            XCTAssertFalse(layout.lines.isEmpty, named)
                            for r in layout.lines {
                                let along = (0...20).flatMap { i -> [CGPoint] in
                                    let x = r.minX + r.width * CGFloat(i) / 20
                                    return [CGPoint(x: x, y: r.minY), CGPoint(x: x, y: r.maxY)]
                                }
                                let ends = [CGPoint(x: r.minX, y: r.midY), CGPoint(x: r.maxX, y: r.midY)]
                                XCTAssertTrue((along + ends).allSatisfy { layout.body.contains($0) }, "\(named): holds \(r)")
                                XCTAssertTrue(layout.textBox.insetBy(dx: -1, dy: -1).contains(r), "\(named): the ink is in the words' box")
                            }
                        }
                    }
                }
            }
        }
        // Moved, or its tail pointed elsewhere, a tight balloon keeps its shape and margin
        for (style, shape) in [(BalloonStyle.shout, BalloonShape.burst), (.thought, .cloud), (.caption, .notched)] {
            let tight = balloon(style, BalloonLook(shape: shape, margin: 0))
            var moved = tight
            moved.center = CGPoint(x: 537, y: 488)
            moved.tail = tight.tail.map { CGPoint(x: $0.x - 60, y: $0.y + 20) }
            let before = BalloonLayout(tight), after = BalloonLayout(moved)
            XCTAssertEqual(after.margin, before.margin, "\(shape): its margin")
            let a = before.body.boundingBoxOfPath, b = after.body.boundingBoxOfPath
            if style == .caption {
                XCTAssertEqual(b.width, a.width, accuracy: 0.01, "\(shape): its shape, moved")
                XCTAssertEqual(b.minX - a.minX, 37, accuracy: 0.01)
            }
            XCTAssertTrue(after.lines.flatMap { corners($0) }.allSatisfy { after.body.contains($0) }, "\(shape): its words, moved")
        }
        for wrap: CGFloat in [200, 90] {
            let usual = BalloonLayout(balloon(.speech, tail: nil, wrap: wrap)).body.boundingBoxOfPath
            let tight = BalloonLayout(balloon(.speech, BalloonLook(margin: 0), tail: nil, wrap: wrap)).body.boundingBoxOfPath
            XCTAssertLessThan(tight.width * tight.height, usual.width * usual.height * 0.85, "an oval \(wrap) wide, tighter")
        }
    }

    // MARK: - Saving

    /// A look saves with its balloon and comes back; the plain look saves nothing, so a
    /// balloon from before looks reads as it was; a part a later build adds reads as plain.
    func testALookSavesWithItsBalloon() throws {
        let plain = try JSONSerialization.jsonObject(with: JSONEncoder().encode(balloon(.speech))) as? [String: Any]
        for key in ["shape", "line", "fill", "tailShape", "tailWidth", "tailBase", "margin", "tailPinned"] {
            XCTAssertNil(plain?[key], "the plain look saves no \(key)")
        }
        var looked = balloon(.shout, BalloonLook(shape: .jagged, line: .electric, fill: .yellow, tail: .lightning, tailWidth: 1.5,
                                                 tailBase: 2.5, margin: 0.75))
        looked.tailPinned = true
        let data = try JSONEncoder().encode(looked)
        XCTAssertEqual(try JSONDecoder().decode(Balloon.self, from: data), looked)

        let later = try XCTUnwrap(String(data: data, encoding: .utf8)).replacingOccurrences(of: "\"jagged\"", with: "\"spiral\"")
        let read = try JSONDecoder().decode(Balloon.self, from: Data(later.utf8))
        XCTAssertNil(read.look.shape, "a shape this build does not know reads as the kind's own")
        XCTAssertEqual(read.look.line, .electric, "and the rest as saved")
        XCTAssertEqual(read.look.margin, 0.75)
    }

    // MARK: - The tool

    /// Each kind keeps the look last given one of its kind for the next: set with none
    /// picked up, or on a picked-up balloon, where it is a step to undo.
    func testEachKindKeepsItsLookForTheNext() throws {
        let harness = try EngineHarness(width: 800, height: 600)
        let viewModel = harness.viewModel, renderer = harness.renderer
        let narration = BalloonLook(shape: .slanted, fill: .yellow)
        viewModel.balloonStyle = .caption
        viewModel.setBalloonLook(narration, as: "Balloon Fill", renderer: renderer)
        XCTAssertTrue(viewModel.balloons.isEmpty, "with nothing picked up, only the next one's")
        viewModel.letteringDown(at: CGPoint(x: 200, y: 450), renderer: renderer)
        viewModel.letteringUp(renderer: renderer)
        XCTAssertEqual(viewModel.selectedBalloon?.look, narration, "a caption placed in it")

        viewModel.letteringDown(at: CGPoint(x: 700, y: 50), renderer: renderer)
        viewModel.letteringUp(renderer: renderer)
        viewModel.restyleSelectedBalloon(.speech, renderer: renderer)
        viewModel.letteringDown(at: CGPoint(x: 600, y: 200), renderer: renderer)
        viewModel.letteringUp(renderer: renderer)
        XCTAssertEqual(viewModel.selectedBalloon?.look, BalloonLook(), "speech keeps its own, the plain look")

        let layer = try XCTUnwrap(viewModel.letteringLayer)
        let steps = viewModel.undoManager.undoCount
        let whisper = BalloonLook(line: .dashed)
        viewModel.setBalloonLook(whisper, as: "Balloon Line", renderer: renderer)
        XCTAssertEqual(viewModel.selectedBalloon?.look, whisper)
        XCTAssertEqual(viewModel.balloonLook(for: .speech), whisper, "and the next speech balloon's")
        XCTAssertEqual(viewModel.undoManager.undoCount, steps + 1, "a step")
        viewModel.setBalloonLook(whisper, as: "Balloon Line", renderer: renderer)
        viewModel.setBalloonLook(BalloonLook(line: .wavy), as: "Balloon Line", renderer: renderer)
        XCTAssertEqual(viewModel.undoManager.undoCount, steps + 1, "nothing to change is no step; lines in a row are one")
        viewModel.performUndo(renderer: renderer)
        XCTAssertEqual(viewModel.selectedBalloon?.look ?? viewModel.balloons.last?.look, BalloonLook(), "undone")
        XCTAssertEqual(layer.lettering?.count, 2)
    }

    /// A balloon whose kind changes takes the new kind's shape and tail and keeps its line
    /// and fill; choosing a tail's shape puts a tail on one with none.
    func testChangingKindKeepsTheInk() throws {
        let harness = try EngineHarness(width: 800, height: 600)
        let viewModel = harness.viewModel, renderer = harness.renderer
        viewModel.balloonLooks[.shout] = BalloonLook(shape: .blast, tail: .lightning)
        viewModel.letteringDown(at: CGPoint(x: 400, y: 300), renderer: renderer)
        viewModel.letteringUp(renderer: renderer)
        viewModel.setBalloonLook(BalloonLook(shape: .wobbly, line: .double, fill: .pink, tail: .straight), as: "Balloon Fill",
                                 renderer: renderer)
        let steps = viewModel.undoManager.undoCount
        viewModel.restyleSelectedBalloon(.shout, renderer: renderer)
        XCTAssertEqual(viewModel.selectedBalloon?.look, BalloonLook(shape: .blast, line: .double, fill: .pink, tail: .lightning))
        XCTAssertEqual(viewModel.undoManager.undoCount, steps + 1)
        viewModel.restyleSelectedBalloon(.shout, renderer: renderer)
        XCTAssertEqual(viewModel.undoManager.undoCount, steps + 1, "the same kind is no step")

        viewModel.changeSelectedBalloon("Balloon Tail", renderer: renderer) { $0.tail = nil }
        viewModel.setBalloonLook(BalloonLook(shape: .blast, line: .double, fill: .pink, tail: .curved), as: "Tail Shape",
                                 addingTail: true, renderer: renderer)
        XCTAssertNotNil(viewModel.selectedBalloon?.tail, "a tail's shape chosen puts one on")
        XCTAssertEqual(viewModel.selectedBalloon?.tailShape, .curved)

        viewModel.restyleSelectedBalloon(.caption, renderer: renderer)
        XCTAssertEqual(viewModel.selectedBalloon?.shape, .box, "a caption's own")
        XCTAssertEqual(viewModel.selectedBalloon?.look.fill, .pink, "the fill kept")
    }

    /// A pinned tip stays on the page where it is, on its speaker, as the balloon is moved;
    /// its tip is still pointed by its handle; unpinned, it goes with the balloon again.
    /// Pinning and unpinning are steps, and pinning a pinned tip is none.
    func testAPinnedTipStaysWhenTheBalloonMoves() throws {
        let harness = try EngineHarness(width: 800, height: 600)
        let viewModel = harness.viewModel, renderer = harness.renderer
        viewModel.letteringDown(at: CGPoint(x: 300, y: 300), renderer: renderer)
        viewModel.letteringUp(renderer: renderer)
        let placed = try XCTUnwrap(viewModel.selectedBalloon)
        let tip = try XCTUnwrap(placed.tail)
        XCTAssertFalse(placed.tailPinned, "a new balloon's tip goes with it")
        let steps = viewModel.undoManager.undoCount

        viewModel.pinSelectedTail(true, renderer: renderer)
        viewModel.pinSelectedTail(true, renderer: renderer)
        XCTAssertEqual(viewModel.selectedBalloon?.tailPinned, true)
        XCTAssertEqual(viewModel.undoManager.undoCount, steps + 1, "pinning a pinned tip is no step")

        viewModel.letteringDown(at: CGPoint(x: 300, y: 300), renderer: renderer)
        viewModel.letteringDrag(to: CGPoint(x: 400, y: 300), renderer: renderer)
        viewModel.letteringDrag(to: CGPoint(x: 500, y: 340), renderer: renderer)
        viewModel.letteringUp(renderer: renderer)
        XCTAssertEqual(viewModel.selectedBalloon?.center, CGPoint(x: 500, y: 340), "the balloon moves")
        XCTAssertEqual(viewModel.selectedBalloon?.tail, tip, "its pinned tip stays on its speaker")
        let layer = try XCTUnwrap(viewModel.letteringLayer)
        // A quarter of the way back from the tip to the balloon is on the tail
        let onTail = CGPoint(x: tip.x + (500 - tip.x) * 0.25, y: tip.y + (340 - tip.y) * 0.25)
        XCTAssertEqual(harness.pixels(of: layer.texture).at(x: Int(onTail.x), y: Int(onTail.y)).w, 1, accuracy: 0.05,
                       "the tail is drawn to it")

        // Its handle still points it
        viewModel.letteringDown(at: tip, renderer: renderer)
        viewModel.letteringDrag(to: CGPoint(x: 600, y: 120), renderer: renderer)
        viewModel.letteringUp(renderer: renderer)
        XCTAssertEqual(viewModel.selectedBalloon?.tail, CGPoint(x: 600, y: 120))
        XCTAssertEqual(viewModel.selectedBalloon?.tailPinned, true)

        viewModel.pinSelectedTail(false, renderer: renderer)
        viewModel.letteringDown(at: CGPoint(x: 500, y: 340), renderer: renderer)
        viewModel.letteringDrag(to: CGPoint(x: 450, y: 340), renderer: renderer)
        viewModel.letteringUp(renderer: renderer)
        XCTAssertEqual(viewModel.selectedBalloon?.tail, CGPoint(x: 550, y: 120), "unpinned, it goes with the balloon")
        XCTAssertEqual(viewModel.undoManager.undoCount, steps + 5)

        for _ in 0..<4 { viewModel.performUndo(renderer: renderer) }
        XCTAssertEqual(viewModel.balloons.first?.tailPinned, true)
        viewModel.performUndo(renderer: renderer)
        XCTAssertEqual(viewModel.balloons.first?.tailPinned, false, "the pin undone")
    }

    /// The diamond at the end of the tail's base is taken and dragged out along the base,
    /// setting its width, as a step; the next balloon of the kind takes it too.
    func testTheBaseIsDraggedToItsWidth() throws {
        let harness = try EngineHarness(width: 800, height: 600)
        let viewModel = harness.viewModel, renderer = harness.renderer
        viewModel.letteringDown(at: CGPoint(x: 400, y: 300), renderer: renderer)
        viewModel.letteringUp(renderer: renderer)
        viewModel.changeSelectedBalloon("Edit Words", renderer: renderer) { $0.text = "Who goes there? Show yourself!" }
        let placed = try XCTUnwrap(viewModel.selectedBalloon)
        XCTAssertNil(placed.look.tailBase)
        let layout = BalloonLayout(placed)
        let handle = try XCTUnwrap(layout.baseHandle)
        let ends = try XCTUnwrap(layout.base)
        let middle = CGPoint(x: (ends.left.x + ends.right.x) / 2, y: (ends.left.y + ends.right.y) / 2)
        let length = hypot(ends.left.x - ends.right.x, ends.left.y - ends.right.y)
        let along = CGPoint(x: (ends.left.x - ends.right.x) / length, y: (ends.left.y - ends.right.y) / length)
        let steps = viewModel.undoManager.undoCount

        viewModel.letteringDown(at: handle, renderer: renderer)
        viewModel.letteringDrag(to: CGPoint(x: middle.x + along.x * 15, y: middle.y + along.y * 15), renderer: renderer)
        viewModel.letteringDrag(to: CGPoint(x: middle.x + along.x * 26, y: middle.y + along.y * 26), renderer: renderer)
        viewModel.letteringUp(renderer: renderer)
        let base = try XCTUnwrap(viewModel.selectedBalloon?.look.tailBase)
        XCTAssertEqual(base, 52 / placed.fontSize, accuracy: 0.3, "twice the drag's distance from the middle")
        XCTAssertEqual(viewModel.selectedBalloon?.center, placed.center, "the body stays")
        XCTAssertEqual(viewModel.selectedBalloon?.tail, placed.tail, "and the tip")
        XCTAssertEqual(viewModel.undoManager.undoCount, steps + 1, "one step")
        XCTAssertEqual(viewModel.balloonLook(for: .speech).tailBase, base, "the next speech balloon's too")

        viewModel.performUndo(renderer: renderer)
        XCTAssertNil(viewModel.balloons.first?.look.tailBase, "undone")
    }

    /// A margin set on a picked-up balloon is a step, kept for the next balloon of its kind,
    /// and stays when its kind changes, as its line and fill do. A balloon drawn by hand keeps
    /// its outline: its words wrap afresh inside it, wider with less room, narrower with more.
    func testAMarginIsKeptAndADrawnBalloonsWordsRewrap() throws {
        let harness = try EngineHarness(width: 800, height: 600)
        let viewModel = harness.viewModel, renderer = harness.renderer
        viewModel.letteringDown(at: CGPoint(x: 400, y: 300), renderer: renderer)
        viewModel.letteringUp(renderer: renderer)
        viewModel.changeSelectedBalloon("Edit Words", renderer: renderer) { $0.text = "Who goes there? Show yourself!" }
        let placed = try XCTUnwrap(viewModel.selectedBalloon)
        let steps = viewModel.undoManager.undoCount
        viewModel.setBalloonLook(BalloonLook(margin: 2), as: "Balloon Margin", renderer: renderer)
        viewModel.setBalloonLook(BalloonLook(margin: 2.25), as: "Balloon Margin", renderer: renderer)
        let roomy = try XCTUnwrap(viewModel.selectedBalloon)
        XCTAssertEqual(roomy.look.margin, 2.25)
        XCTAssertEqual(viewModel.undoManager.undoCount, steps + 1, "margins in a row are one step")
        XCTAssertEqual(viewModel.balloonLook(for: .speech).margin, 2.25, "the next speech balloon's too")
        XCTAssertGreaterThan(BalloonLayout(roomy).body.boundingBoxOfPath.width,
                             BalloonLayout(placed).body.boundingBoxOfPath.width + 20, "more room")
        XCTAssertEqual(roomy.wrapWidth, placed.wrapWidth, "a plain balloon's words wrap as they did")

        viewModel.restyleSelectedBalloon(.caption, renderer: renderer)
        XCTAssertEqual(viewModel.selectedBalloon?.look.margin, 2.25, "kept as the kind changes")
        viewModel.performUndo(renderer: renderer)
        viewModel.performUndo(renderer: renderer)
        XCTAssertEqual(viewModel.balloons.first?.look.margin, 1, "undone")

        // A loop drawn round where the words go
        viewModel.balloonStyle = .speech
        viewModel.balloonLooks[.speech] = BalloonLook()
        let loop = (0...206).map { i -> CGPoint in
            let t = 2 * CGFloat.pi * CGFloat(i) / 200
            return CGPoint(x: 400 + 200 * cos(t), y: 330 + 120 * sin(t))
        }
        viewModel.selectedBalloonID = nil
        viewModel.drawBalloon(loop, renderer: renderer)
        viewModel.changeSelectedBalloon("Edit Words", renderer: renderer) {
            $0.text = "Who goes there? Show yourself, or I shall have to come down and find you myself!"
        }
        let drawn = try XCTUnwrap(viewModel.selectedBalloon)
        let outline = try XCTUnwrap(drawn.drawn)
        viewModel.setBalloonLook(BalloonLook(margin: 0.25), as: "Balloon Margin", renderer: renderer)
        let tight = try XCTUnwrap(viewModel.selectedBalloon)
        XCTAssertEqual(tight.drawn, outline, "the outline as drawn")
        XCTAssertGreaterThan(tight.wrapWidth, drawn.wrapWidth + 20, "the words wider inside it")
        viewModel.setBalloonLook(BalloonLook(margin: 2), as: "Balloon Margin", renderer: renderer)
        let roomyDrawn = try XCTUnwrap(viewModel.selectedBalloon)
        XCTAssertLessThan(roomyDrawn.wrapWidth, drawn.wrapWidth - 20, "narrower with more room")
        XCTAssertEqual(roomyDrawn.drawn, outline)
    }
}
