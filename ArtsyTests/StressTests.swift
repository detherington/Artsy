import XCTest
import CoreGraphics
@testable import Artsy

/// A long random session, as close as a machine gets to someone drawing for an hour: every
/// brush and tool, layer operations, undo and redo, in a seeded order. Nothing may crash,
/// the picture must always equal a full recomposite, memory must stay bounded.
final class StressTests: XCTestCase {
    /// SplitMix64: repeatable, however the platform's generators change.
    private struct SeededRandom: RandomNumberGenerator {
        var state: UInt64
        mutating func next() -> UInt64 {
            state &+= 0x9E3779B97F4A7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
            z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
            return z ^ (z >> 31)
        }
    }

    private func worst(_ a: PixelGrid, _ b: PixelGrid) -> Float {
        var worst: Float = 0
        for i in a.values.indices { worst = max(worst, abs(a.values[i] - b.values[i])) }
        return worst
    }

    func testARandomSessionNeverCorruptsThePicture() throws {
        for seed in [20261006, 7, 99] as [UInt64] {
            try session(seed: seed, steps: 220)
        }
    }

    private func session(seed: UInt64, steps: Int) throws {
        var rng = SeededRandom(state: seed)
        let width = 320, height = 200
        let harness = try EngineHarness(width: width, height: height)
        let context = harness.context, renderer = harness.renderer, viewModel = harness.viewModel
        let brushes = BrushDescriptor.allDefaults + [.eraser]
        let symmetries: [SymmetryMode] = [.off, .off, .horizontal, .quad, .radial(3)]
        let blendModes = LayerBlendMode.allCases
        var compositeChecks = 0
        func point() -> CGPoint {
            CGPoint(x: CGFloat.random(in: 0...CGFloat(width), using: &rng), y: CGFloat.random(in: 0...CGFloat(height), using: &rng))
        }
        func rect() -> CGRect {
            let a = point(), b = point()
            return CGRect(x: min(a.x, b.x), y: min(a.y, b.y), width: max(8, abs(a.x - b.x)), height: max(8, abs(a.y - b.y)))
        }
        func stroke() -> [StrokePoint] {
            let pressure = Float.random(in: 0.3...1, using: &rng)
            switch Int.random(in: 0..<6, using: &rng) {
            case 0: return StrokeFixtures.line(from: point(), to: point(), pressure: pressure...pressure)
            case 1: return StrokeFixtures.wave(from: point(), length: CGFloat.random(in: 40...250, using: &rng), amplitude: 30, cycles: 2)
            case 2: return StrokeFixtures.spiral(center: point(), radius: 3...CGFloat.random(in: 20...80, using: &rng), turns: 2)
            case 3: return StrokeFixtures.zigzag(from: point(), length: 160, height: 60, teeth: 5)
            case 4: return StrokeFixtures.dot(at: point(), pressure: pressure)
            default: return StrokeFixtures.held(StrokeFixtures.rough(StrokeFixtures.circlePositions(center: point(), radius: 50), wobble: 6), for: 0.7)
            }
        }
        var layerLimitHits = 0

        for step in 0..<steps {
            let layerStack = harness.layerStack
            switch Int.random(in: 0..<100, using: &rng) {
            case 0..<52:
                let brush = brushes.randomElement(using: &rng)!
                harness.select(brush)
                viewModel.brushSize = Float.random(in: 3...60, using: &rng)
                viewModel.brushOpacity = Float.random(in: 0.3...1, using: &rng)
                viewModel.currentColor = StrokeColor(red: Float.random(in: 0...1, using: &rng), green: Float.random(in: 0...1, using: &rng),
                                                     blue: Float.random(in: 0...1, using: &rng), alpha: 1)
                viewModel.symmetryMode = symmetries.randomElement(using: &rng)!
                viewModel.smoothingMode = [SmoothingMode.none, .oneEuro].randomElement(using: &rng)!
                let points = stroke()
                let pointsPerFrame = Int.random(in: 1...9, using: &rng)
                if step % 10 == 3, points.count > 20 {
                    // Mid-stroke, the incremental picture has to equal a full recomposite
                    renderer.beginStroke()
                    viewModel.beginStroke(point: points[0])
                    for (index, p) in points.dropFirst().prefix(points.count / 2).enumerated() {
                        viewModel.continueStroke(point: p)
                        if index % pointsPerFrame == 0 { harness.renderFrame() }
                    }
                    let incremental = harness.shown()
                    let background = layerStack.layers[0]
                    background.isVisible.toggle()
                    harness.renderFrame()
                    background.isVisible.toggle()
                    let full = harness.shown()
                    XCTAssertLessThan(worst(incremental, full), 0.012, "seed \(seed), step \(step), \(brush.name)")
                    compositeChecks += 1
                    for p in points.dropFirst(1 + points.count / 2) { viewModel.continueStroke(point: p) }
                    renderer.finalizeStroke()
                    viewModel.endStroke()
                } else {
                    harness.draw(points, pointsPerFrame: pointsPerFrame)
                }
            case 52..<60:
                viewModel.saveUndoSnapshot(renderer: renderer, description: "Layers")
                switch Int.random(in: 0..<6, using: &rng) {
                case 0:
                    do { _ = try layerStack.addLayer(above: layerStack.activeLayerIndex) } catch { layerLimitHits += 1 }
                case 1:
                    if layerStack.layers.count > 1 { layerStack.removeLayer(at: Int.random(in: 0..<layerStack.layers.count, using: &rng)) }
                case 2:
                    layerStack.moveLayer(from: Int.random(in: 0..<layerStack.layers.count, using: &rng),
                                         to: Int.random(in: 0..<layerStack.layers.count, using: &rng))
                case 3:
                    layerStack.layers.randomElement(using: &rng)!.isVisible.toggle()
                case 4:
                    layerStack.layers.randomElement(using: &rng)!.opacity = Float.random(in: 0.2...1, using: &rng)
                default:
                    layerStack.layers.randomElement(using: &rng)!.blendMode = blendModes.randomElement(using: &rng)!
                }
                layerStack.activeLayerIndex = Int.random(in: 0..<layerStack.layers.count, using: &rng)
            case 60..<68:
                if viewModel.undoManager.canUndo { viewModel.performUndo(renderer: renderer) }
            case 68..<73:
                if viewModel.undoManager.canRedo { viewModel.performRedo(renderer: renderer) }
            case 73..<80:
                guard let layer = layerStack.activeLayer else { continue }
                viewModel.saveUndoSnapshot(renderer: renderer, description: "Move Selection")
                let mover = SelectionMoveHandler()
                mover.begin(selectionPath: CGPath(rect: rect(), transform: nil), layer: layer, context: context,
                            textureManager: renderer.textureManager)
                mover.updateOffset(dx: CGFloat.random(in: -80...80, using: &rng), dy: CGFloat.random(in: -80...80, using: &rng))
                mover.commit(layer: layer, context: context, textureManager: renderer.textureManager, compositor: renderer.compositor)
            case 80..<86:
                guard let layer = layerStack.activeLayer else { continue }
                viewModel.saveUndoSnapshot(renderer: renderer, description: "Transform")
                let withSelection = Bool.random(using: &rng)
                guard let session = TransformSession.begin(targetLayer: layer, canvasSize: viewModel.canvasSize,
                                                           selectionPath: withSelection ? CGPath(rect: rect(), transform: nil) : nil,
                                                           context: context, textureManager: renderer.textureManager) else { continue }
                session.currentTransform = CGAffineTransform(translationX: CGFloat.random(in: -60...60, using: &rng),
                                                             y: CGFloat.random(in: -60...60, using: &rng))
                    .scaledBy(x: CGFloat.random(in: 0.6...1.5, using: &rng), y: CGFloat.random(in: 0.6...1.5, using: &rng))
                session.commit(context: context, textureManager: renderer.textureManager, compositor: renderer.compositor)
            case 86..<91:
                guard let layer = layerStack.activeLayer else { continue }
                viewModel.saveUndoSnapshot(renderer: renderer, description: "Clear")
                renderer.clearInsideSelection(path: CGPath(ellipseIn: rect(), transform: nil), layer: layer, context: context)
            case 91..<95:
                if layerStack.layers.count > 1 {
                    viewModel.saveUndoSnapshot(renderer: renderer, description: "Merge Down")
                    _ = layerStack.mergeDown(at: Int.random(in: 1..<layerStack.layers.count, using: &rng), renderer: renderer)
                    layerStack.activeLayerIndex = min(layerStack.activeLayerIndex, layerStack.layers.count - 1)
                }
            default:
                guard let layer = layerStack.activeLayer else { continue }
                viewModel.saveUndoSnapshot(renderer: renderer, description: "Shift")
                renderer.shiftLayerContent(layer: layer, dx: Int.random(in: -50...50, using: &rng),
                                           dy: Int.random(in: -50...50, using: &rng), context: context)
            }

            // Invariants, every step
            XCTAssertLessThanOrEqual(viewModel.undoManager.undoCount, viewModel.undoManager.maxUndoLevels)
            XCTAssertFalse(viewModel.isDrawing, "step \(step): no stroke left open")
            XCTAssertTrue((0..<layerStack.layers.count).contains(layerStack.activeLayerIndex), "step \(step): active layer in range")
            if step % 20 == 19 {
                viewModel.undoManager.waitForPendingWork()
                XCTAssertLessThan(context.device.currentAllocatedSize, 2 << 30, "step \(step): memory bounded")
            }
        }
        XCTAssertGreaterThan(compositeChecks, 5, "seed \(seed): the mid-stroke check ran")
        XCTAssertGreaterThan(viewModel.undoManager.undoCount, 20)
        _ = layerLimitHits
    }
}
