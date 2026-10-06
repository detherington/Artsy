import XCTest
@testable import Artsy

/// Stamp brushes: dabs laid along the path, adding up within a stroke.
final class StampBrushTests: XCTestCase {
    private func path(_ samples: [StrokePoint], size: Float = 20) -> StrokePath {
        let path = StrokePath(style: StrokePath.Style(brushSize: size, pressureCurve: .linear,
                                                      dynamics: PressureDynamics(sizeRange: 1...1, opacityRange: 1...1)))
        samples.forEach(path.append)
        return path
    }

    private func settings(_ brush: BrushDescriptor) -> StampSettings {
        guard case .stamp(let settings) = brush.rendering else { fatalError("\(brush.name) is not a stamp brush") }
        return settings
    }

    // MARK: - Placement

    func testDabsAreSpacedByAFractionOfTheirSize() {
        let stroke = path(StrokeFixtures.line(from: CGPoint(x: 0, y: 50), to: CGPoint(x: 200, y: 50)))
        var placer = DabPlacer(strokeSeed: 1)
        let dabs = placer.dabs(along: stroke.points, upTo: 200, brush: .softRound,
                               settings: StampSettings(spacing: 0.25, flow: 1))

        // 20 px dabs at 25% spacing: one every 5 px, starting at the very start of the stroke
        XCTAssertEqual(dabs.count, 41)
        XCTAssertEqual(dabs[0].center.x, 0, accuracy: 0.01)
        for (a, b) in zip(dabs, dabs.dropFirst()) {
            XCTAssertEqual(b.center.x - a.center.x, 5, accuracy: 0.01)
            XCTAssertEqual(a.center.y, 50, accuracy: 0.01)
        }
        XCTAssertEqual(dabs[0].size, 20)
    }

    /// The renderer asks for dabs a little at a time as the path settles. That has to give
    /// exactly the dabs that asking once for the whole stroke would.
    func testLayingDabsInPiecesGivesTheSameDabs() {
        let stroke = path(StrokeFixtures.spiral(center: CGPoint(x: 100, y: 100), radius: 5...80, turns: 3))
        let chalk = settings(.chalk)
        let end = stroke.points.last!.distance

        var whole = DabPlacer(strokeSeed: 42)
        let expected = whole.dabs(along: stroke.points, upTo: end, brush: .chalk, settings: chalk)

        var piecewise = DabPlacer(strokeSeed: 42)
        var collected: [Dab] = []
        for limit in stride(from: CGFloat(0), to: end, by: 13.7) {
            // A throwaway copy for the tail must not disturb the real placer
            var preview = piecewise
            _ = preview.dabs(along: stroke.points, upTo: end, brush: .chalk, settings: chalk)
            collected += piecewise.dabs(along: stroke.points, upTo: limit, brush: .chalk, settings: chalk)
        }
        collected += piecewise.dabs(along: stroke.points, upTo: end, brush: .chalk, settings: chalk)

        XCTAssertEqual(collected.count, expected.count)
        XCTAssertGreaterThan(expected.count, 50)
        for (a, b) in zip(collected, expected) {
            XCTAssertEqual(a.center, b.center)
            XCTAssertEqual(a.size, b.size)
            XCTAssertEqual(a.angle, b.angle)
            XCTAssertEqual(a.opacity, b.opacity)
            XCTAssertEqual(a.seed, b.seed)
        }
    }

    func testTiltAndRotationShapeTheDabs() {
        let stroke = StrokePath(style: StrokePath.Style(
            brushSize: 20, pressureCurve: .linear, dynamics: PressureDynamics(sizeRange: 1...1, opacityRange: 1...1),
            tilt: TiltDynamics(sizeScale: 2, opacityScale: 1, aspect: 1.8)
        ))
        for i in 0..<40 {
            stroke.append(StrokePoint(position: CGPoint(x: CGFloat(i) * 3, y: 50), pressure: 1,
                                      tiltX: 0.9, tiltY: 0, rotation: 30, timestamp: Double(i) / 200))
        }
        var placer = DabPlacer(strokeSeed: 1)
        let dabs = placer.dabs(along: stroke.points, upTo: 100, brush: .chalk, settings: StampSettings(spacing: 0.5, flow: 1))
        let middle = dabs[dabs.count / 2]
        XCTAssertEqual(middle.aspect, 1.8, accuracy: 0.01)
        XCTAssertEqual(middle.size, 40, accuracy: 0.1, "twice as big when flat")
        XCTAssertEqual(middle.angle, 0 + 30 * .pi / 180, accuracy: 0.01, "along the lean, plus the barrel rotation")
    }

    func testJitterVariesFromDabToDabAndStrokeToStroke() {
        let stroke = path(StrokeFixtures.line(from: CGPoint(x: 0, y: 50), to: CGPoint(x: 300, y: 50)))
        let jittery = StampSettings(spacing: 0.2, flow: 0.5, sizeJitter: 0.5, opacityJitter: 0.5, angleJitter: 1, scatter: 0.3)

        var first = DabPlacer(strokeSeed: 7)
        let a = first.dabs(along: stroke.points, upTo: 300, brush: .chalk, settings: jittery)
        var second = DabPlacer(strokeSeed: 8)
        let b = second.dabs(along: stroke.points, upTo: 300, brush: .chalk, settings: jittery)

        XCTAssertGreaterThan(Set(a.map(\.size)).count, a.count / 2, "sizes vary")
        XCTAssertGreaterThan(Set(a.map(\.angle)).count, a.count / 2, "angles vary")
        XCTAssertTrue(a.contains { abs($0.center.y - 50) > 1 }, "scatter moves dabs off the path")
        XCTAssertTrue(a.allSatisfy { $0.size <= 20 && $0.size >= 10 && $0.opacity <= 0.5 && $0.opacity >= 0.25 })
        XCTAssertNotEqual(a.map(\.size), b.map(\.size), "a different stroke gets different jitter")
    }

    /// One dab of a low-flow brush is nearly invisible, so a tap lays several.
    func testATapLeavesAVisibleDot() throws {
        for brush in [BrushDescriptor.softRound, .pencil, .chalk] {
            let harness = try EngineHarness(width: 100, height: 100)
            harness.select(brush)
            harness.viewModel.brushSize = 24
            harness.draw(StrokeFixtures.dot(at: CGPoint(x: 50, y: 50), pressure: 0.8))
            let shown = harness.displayed()
            let darkest = (44...56).flatMap { x in (44...56).map { y in 1 - shown.at(x: x, y: y).x } }.max()!
            XCTAssertGreaterThan(darkest, 0.5, brush.name)
            XCTAssertEqual(shown.at(x: 80, y: 80).x, 1, accuracy: 0.01, "\(brush.name): only where the tap was")
        }
    }

    // MARK: - Accumulation

    private func darkness(at point: (Int, Int), drawing strokes: [[StrokePoint]], brush: BrushDescriptor,
                          opacity: Float = 1) throws -> Float {
        let harness = try EngineHarness(width: 200, height: 200)
        harness.select(brush)
        harness.viewModel.brushSize = 40
        harness.viewModel.brushOpacity = opacity
        strokes.forEach { harness.draw($0) }
        return 1 - harness.displayed().at(x: point.0, y: point.1).x
    }

    /// A wash builds towards the stroke's opacity and stops: going back over it without
    /// lifting the pen adds nothing more.
    func testWashStopsAtTheStrokeOpacity() throws {
        let once = StrokeFixtures.line(from: CGPoint(x: 20, y: 100), to: CGPoint(x: 180, y: 100), pressure: 1...1)
        let there = try darkness(at: (100, 100), drawing: [once], brush: .softRound, opacity: 0.5)
        XCTAssertEqual(there, 0.5, accuracy: 0.04, "the middle of a full-pressure stroke all but reaches the cap")
        XCTAssertLessThanOrEqual(there, 0.501, "and never passes it")

        // The same stroke, then back again and across itself, pen still down
        let scribble = once + once.reversed().enumerated().map { index, point in
            StrokePoint(position: point.position, pressure: 1, tiltX: 0, tiltY: 0, rotation: 0,
                        timestamp: 1 + Double(index) * 0.005)
        }
        let thereAndBack = try darkness(at: (100, 100), drawing: [scribble], brush: .softRound, opacity: 0.5)
        XCTAssertLessThanOrEqual(thereAndBack, 0.501, "going over it again without lifting stays under the cap")
        XCTAssertEqual(thereAndBack, 0.5, accuracy: 0.02)

        // A second stroke is a second coat on top of the first.
        let twoStrokes = try darkness(at: (100, 100), drawing: [once, once], brush: .softRound, opacity: 0.5)
        XCTAssertEqual(twoStrokes, there + (1 - there) * there, accuracy: 0.01)
    }

    /// A build-up brush has no cap: every pass adds paint.
    func testBuildUpKeepsAdding() throws {
        let once = StrokeFixtures.line(from: CGPoint(x: 20, y: 100), to: CGPoint(x: 180, y: 100), pressure: 0.5...0.5)
        let back = once.reversed().enumerated().map { index, point in
            StrokePoint(position: point.position, pressure: 0.5, tiltX: 0, tiltY: 0, rotation: 0,
                        timestamp: 1 + Double(index) * 0.005)
        }
        let single = try darkness(at: (100, 100), drawing: [once], brush: .airbrush)
        let double = try darkness(at: (100, 100), drawing: [once + back], brush: .airbrush)
        XCTAssertGreaterThan(single, 0.1)
        XCTAssertLessThan(single, 0.7, "one light pass of an airbrush is far from solid")
        XCTAssertGreaterThan(double, single * 1.3, "going back over it adds more")

        let halved = try darkness(at: (100, 100), drawing: [once], brush: .airbrush, opacity: 0.5)
        XCTAssertLessThan(halved, single * 0.7, "the opacity slider thins every dab")
    }

    // MARK: - Grain

    /// The paper's tooth belongs to the canvas, not the stroke: drawing the same stroke on
    /// the same spot twice lands pigment on the same peaks.
    func testGrainIsFixedToTheCanvas() throws {
        func coverage(offset: CGFloat) throws -> [Bool] {
            let harness = try EngineHarness(width: 240, height: 80)
            harness.select(.graphiteStick)
            harness.draw(StrokeFixtures.line(from: CGPoint(x: 20 + offset, y: 40), to: CGPoint(x: 200 + offset, y: 40),
                                             pressure: 0.4...0.4))
            let shown = harness.displayed()
            return (40..<180).map { shown.at(x: $0, y: 40).x < 0.75 }
        }
        let first = try coverage(offset: 0)
        XCTAssertTrue(first.contains(true) && first.contains(false), "at light pressure some paper shows through")
        XCTAssertEqual(first, try coverage(offset: 0), "repeatable")

        // Starting the stroke somewhere else moves the dabs, not the paper: the same pixels
        // of paper still take the pigment (give or take the dabs' own jitter).
        let shifted = try coverage(offset: 3)
        let agreeing = zip(first, shifted).filter { $0 == $1 }.count
        XCTAssertGreaterThan(Double(agreeing) / Double(first.count), 0.8)
    }

    /// Height grain: light pressure only reaches the paper's peaks, firm pressure fills in.
    func testFirmerPressureFillsMoreOfThePaper() throws {
        func covered(pressure: Float) throws -> Double {
            let harness = try EngineHarness(width: 240, height: 80)
            harness.select(.graphiteStick)
            harness.draw(StrokeFixtures.line(from: CGPoint(x: 20, y: 40), to: CGPoint(x: 220, y: 40),
                                             pressure: pressure...pressure))
            let shown = harness.displayed()
            let marked = (40..<200).filter { shown.at(x: $0, y: 40).x < 0.9 }.count
            return Double(marked) / 160
        }
        let light = try covered(pressure: 0.15), medium = try covered(pressure: 0.5), firm = try covered(pressure: 1.0)
        XCTAssertLessThan(light, medium)
        XCTAssertLessThan(medium, firm)
        XCTAssertLessThan(light, 0.5)
        XCTAssertGreaterThan(firm, 0.9)
    }
}
