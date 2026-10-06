import XCTest
@testable import Artsy

/// Properties every built-in brush has to have, run over all of them: the sort of thing
/// that is easy to prove for one brush and then quietly lost on another.
final class EveryBrushTests: XCTestCase {
    private var everyBrush: [BrushDescriptor] { BrushDescriptor.allDefaults + [.eraser] }

    private func worst(_ a: PixelGrid, _ b: PixelGrid) -> Float {
        var worst: Float = 0
        for i in a.values.indices { worst = max(worst, abs(a.values[i] - b.values[i])) }
        return worst
    }

    /// A canvas with something on it for every kind of brush to act on: paint to smudge,
    /// to erase, to mix with and to pile on — a translucent fill and a red band across it.
    private func paintedCanvas(width: Int = 256, height: Int = 200) throws -> EngineHarness {
        let harness = try EngineHarness(width: width, height: height)
        harness.fill(harness.drawingLayer, red: 0.2, green: 0.5, blue: 0.9, alpha: 0.6)
        harness.select(.hardRound)
        harness.viewModel.brushSize = 30
        harness.viewModel.currentColor = StrokeColor(red: 0.9, green: 0.15, blue: 0.1, alpha: 1)
        harness.draw(StrokeFixtures.line(from: CGPoint(x: 0, y: 110), to: CGPoint(x: CGFloat(width), y: 110), pressure: 1...1))
        harness.viewModel.undoManager.clear()
        return harness
    }

    private func use(_ brush: BrushDescriptor, on harness: EngineHarness) {
        harness.select(brush)
        harness.viewModel.brushSize = 24
        harness.viewModel.currentColor = StrokeColor(red: 0.95, green: 0.8, blue: 0.1, alpha: 1)
        harness.viewModel.brushOpacity = 0.8
    }

    private var sheet: [[StrokePoint]] {
        [StrokeFixtures.wave(from: CGPoint(x: 20, y: 110), length: 216, amplitude: 40, cycles: 2),
         StrokeFixtures.spiral(center: CGPoint(x: 128, y: 100), radius: 6...60, turns: 2)]
    }

    func testEveryBrushDrawsTheSameWhateverTheFrameCadence() throws {
        for brush in everyBrush {
            var results: [PixelGrid] = []
            for pointsPerFrame in [2, Int.max] {
                let harness = try paintedCanvas()
                use(brush, on: harness)
                sheet.forEach { harness.draw($0, pointsPerFrame: pointsPerFrame) }
                results.append(harness.shown())
            }
            XCTAssertLessThan(worst(results[0], results[1]), 0.012, brush.name)
        }
    }

    func testUndoAndRedoRestoreTheLayerExactlyForEveryBrush() throws {
        for brush in everyBrush {
            let harness = try paintedCanvas()
            let before = harness.pixels(of: harness.drawingLayer.texture)
            let heightsBefore = harness.heights(of: harness.drawingLayer)
            use(brush, on: harness)
            sheet.forEach { harness.draw($0) }
            let after = harness.pixels(of: harness.drawingLayer.texture)
            let heightsAfter = harness.heights(of: harness.drawingLayer)
            XCTAssertGreaterThan(worst(before, after) + worst(heightsBefore, heightsAfter), 0.05, "\(brush.name) changed something")

            harness.viewModel.performUndo(renderer: harness.renderer)
            harness.viewModel.performUndo(renderer: harness.renderer)
            XCTAssertEqual(worst(harness.pixels(of: harness.drawingLayer.texture), before), 0, "\(brush.name): undo")
            XCTAssertEqual(worst(harness.heights(of: harness.drawingLayer), heightsBefore), 0, "\(brush.name): undo, thickness")
            harness.viewModel.performRedo(renderer: harness.renderer)
            harness.viewModel.performRedo(renderer: harness.renderer)
            XCTAssertEqual(worst(harness.pixels(of: harness.drawingLayer.texture), after), 0, "\(brush.name): redo")
            XCTAssertEqual(worst(harness.heights(of: harness.drawingLayer), heightsAfter), 0, "\(brush.name): redo, thickness")
        }
    }

    /// Mid-stroke, the regions recomposited frame by frame — colour and thickness — must add
    /// up to what a full recomposite gives, for every brush and on a blended layer.
    func testCompositeWhileDrawingMatchesAFullRecompositeForEveryBrush() throws {
        for brush in everyBrush {
            let harness = try paintedCanvas()
            harness.fill(harness.backgroundLayer, red: 0.9, green: 0.9, blue: 0.8, alpha: 0.7)
            let upper = try harness.addLayer(blendMode: .multiply, opacity: 0.6)
            harness.fill(upper, red: 0.9, green: 0.8, blue: 0.3, alpha: 0.5)
            harness.layerStack.activeLayerIndex = 1
            harness.drawingLayer.opacity = 0.75
            use(brush, on: harness)
            harness.viewModel.symmetryMode = .horizontal

            let points = sheet[1]
            harness.renderer.beginStroke()
            harness.viewModel.beginStroke(point: points[0])
            for point in points.dropFirst(1).prefix(120) {
                harness.viewModel.continueStroke(point: point)
                harness.renderFrame()
            }
            let incremental = harness.shown()
            // Hiding and showing a layer changes the scene, which forces full recomposites
            upper.isVisible = false
            harness.renderFrame()
            upper.isVisible = true
            let full = harness.shown()
            XCTAssertLessThan(worst(incremental, full), 0.012, brush.name)
            harness.renderer.finalizeStroke()
            harness.viewModel.endStroke()
        }
    }

    /// With symmetry on, every brush changes both halves of the canvas about equally.
    func testSymmetryGivesEveryBrushTwoHalves() throws {
        for brush in everyBrush {
            let harness = try paintedCanvas()
            let before = harness.shown()
            use(brush, on: harness)
            harness.viewModel.symmetryMode = .horizontal
            harness.draw(StrokeFixtures.wave(from: CGPoint(x: 10, y: 110), length: 100, amplitude: 40, cycles: 1.5))
            let after = harness.shown()
            func change(_ xs: Range<Int>) -> Float {
                var total: Float = 0
                for y in 0..<200 { for x in xs {
                    let a = after.at(x: x, y: y), b = before.at(x: x, y: y)
                    total += abs(a.x - b.x) + abs(a.y - b.y) + abs(a.z - b.z)
                } }
                return total
            }
            let left = change(0..<128), right = change(128..<256)
            XCTAssertGreaterThan(left, 10, "\(brush.name) left")
            XCTAssertGreaterThan(right, left * 0.5, "\(brush.name): the mirrored copy")
            XCTAssertGreaterThan(left, right * 0.5, "\(brush.name): about as much on each side")
        }
    }
}
