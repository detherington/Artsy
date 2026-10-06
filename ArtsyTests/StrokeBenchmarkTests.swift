import XCTest
import Metal
@testable import Artsy

/// Timings for the hot paths of drawing. These print numbers rather than assert on them;
/// look for the `BENCHMARK` lines in the test log. Debug builds are several times slower on
/// the CPU side, so compare like with like — for representative numbers run
///
///     xcodebuild test -project Artsy.xcodeproj -scheme Artsy -destination 'platform=macOS' \
///         -configuration Release ENABLE_TESTABILITY=YES -only-testing:ArtsyTests/StrokeBenchmarkTests
final class StrokeBenchmarkTests: XCTestCase {
    #if DEBUG
    private let build = "debug"
    #else
    private let build = "release"
    #endif

    private func milliseconds(_ body: () -> Void) -> Double {
        let start = DispatchTime.now().uptimeNanoseconds
        body()
        return Double(DispatchTime.now().uptimeNanoseconds - start) / 1e6
    }

    private func median(_ values: [Double]) -> Double {
        values.sorted()[values.count / 2]
    }

    /// Cost of one frame while a stroke is in progress, as the stroke gets longer.
    /// `cpu` is the main-thread time to encode the frame; `frame` also waits for the GPU.
    func testFrameCostWhileDrawing() throws {
        let harness = try EngineHarness(width: 2048, height: 2048)
        harness.select(.softRound)

        // Hatching back and forth across the canvas, ~7 px between samples.
        var travelled = 0.0
        var timestamp = 0.0
        func nextPoint() -> StrokePoint {
            travelled += 7
            timestamp += 0.005
            let lap = (travelled / 1600).rounded(.down)
            let along = travelled - lap * 1600
            let x = Int(lap) % 2 == 0 ? 220 + along : 1820 - along
            return StrokePoint(position: CGPoint(x: x, y: 1900 - lap * 14), pressure: 0.7,
                               tiltX: 0, tiltY: 0, rotation: 0, timestamp: timestamp)
        }

        harness.renderer.beginStroke()
        harness.viewModel.beginStroke(point: nextPoint())

        for target in [2_000.0, 10_000, 30_000, 60_000] {
            while travelled < target { harness.viewModel.continueStroke(point: nextPoint()) }
            harness.renderFrame()

            var cpu: [Double] = []
            var frame: [Double] = []
            for _ in 0..<15 {
                harness.viewModel.continueStroke(point: nextPoint())
                let commandBuffer = harness.context.commandQueue.makeCommandBuffer()!
                var encode = 0.0
                frame.append(milliseconds {
                    encode = milliseconds { harness.renderer.encodeFrame(into: commandBuffer) }
                    commandBuffer.commit()
                    commandBuffer.waitUntilCompleted()
                })
                cpu.append(encode)
            }
            print(String(format: "BENCHMARK frame-while-drawing (%@) | stroke path %6.0f px | cpu %6.2f ms | frame %6.2f ms",
                         build, target, median(cpu), median(frame)))
        }

        harness.renderer.finalizeStroke()
        harness.viewModel.endStroke()
    }

    /// Cost of one frame of smudging, which lays every dab straight into the layer with
    /// three encoders each. A fast stroke (≈ 25 px per frame) with the built-in Smudge at
    /// 36 px, and the same with a 200 px brush, over paint.
    func testSmudgeFrameCost() throws {
        for size in [Float(36), 200] {
            let harness = try EngineHarness(width: 2048, height: 2048)
            harness.fill(harness.drawingLayer, red: 0.8, green: 0.3, blue: 0.2)
            harness.select(.smudge)
            harness.viewModel.brushSize = size

            var x = 200.0
            var timestamp = 0.0
            func nextPoint() -> StrokePoint {
                x += 25
                timestamp += 1.0 / 120
                return StrokePoint(position: CGPoint(x: x, y: 1000 + 200 * sin(x / 300)), pressure: 0.8,
                                   tiltX: 0, tiltY: 0, rotation: 0, timestamp: timestamp)
            }
            harness.renderer.beginStroke()
            harness.viewModel.beginStroke(point: nextPoint())
            harness.viewModel.continueStroke(point: nextPoint())
            harness.renderFrame()

            var cpu: [Double] = []
            var frame: [Double] = []
            for _ in 0..<40 {
                harness.viewModel.continueStroke(point: nextPoint())
                let commandBuffer = harness.context.commandQueue.makeCommandBuffer()!
                var encode = 0.0
                frame.append(milliseconds {
                    encode = milliseconds { harness.renderer.encodeFrame(into: commandBuffer) }
                    commandBuffer.commit()
                    commandBuffer.waitUntilCompleted()
                })
                cpu.append(encode)
            }
            harness.renderer.finalizeStroke()
            harness.viewModel.endStroke()
            let dabsPerFrame = 25 / (0.08 * Double(size) * 0.8)
            print(String(format: "BENCHMARK smudge-frame (%@) | %3.0f px brush, ~%2.0f dabs per frame | cpu %5.2f ms | frame %5.2f ms",
                         build, size, dabsPerFrame, median(cpu), median(frame)))
        }
    }

    /// What committing one stroke costs at pen-up: time until the GPU has merged it, and the
    /// undo memory it adds. A 600 px stroke with Soft Round.
    func testStrokeCommit() throws {
        for layerCount in [2, 8] {
            let harness = try EngineHarness(width: 2048, height: 2048)
            while harness.layerStack.layers.count < layerCount { try harness.addLayer() }
            harness.layerStack.activeLayerIndex = 1
            harness.select(.softRound)

            var penUp: [Double] = []
            for stroke in 0..<10 {
                let y = CGFloat(300 + stroke * 150)
                let points = StrokeFixtures.line(from: CGPoint(x: 300, y: y), to: CGPoint(x: 900, y: y))
                harness.renderer.beginStroke()
                harness.viewModel.beginStroke(point: points[0])
                points.dropFirst().forEach(harness.viewModel.continueStroke(point:))
                harness.renderFrame()
                penUp.append(milliseconds {
                    harness.renderer.finalizeStroke()
                    harness.viewModel.endStroke()
                    let fence = harness.context.commandQueue.makeCommandBuffer()!
                    fence.commit()
                    fence.waitUntilCompleted()
                })
            }
            let megabytes = Double(harness.viewModel.undoManager.textureBytes) / 10 / (1024 * 1024)
            print(String(format: "BENCHMARK stroke-commit (%@) | %d layers at 2048² | pen-up %5.2f ms | %.2f MB of undo per stroke",
                         build, layerCount, median(penUp), megabytes))
        }
    }

    /// The limits step 6 opened up: an 8192² canvas with 12 layers. What a frame costs while
    /// drawing and while idle, what a stroke's commit costs, and what the undo step of an
    /// action that changes no pixels (a selection) and of one that changes one layer (a
    /// fill) costs — call and GPU.
    func testLargeCanvasCosts() throws {
        let harness = try EngineHarness(width: 8192, height: 8192)
        while harness.layerStack.layers.count < 12 { try harness.addLayer() }
        harness.layerStack.activeLayerIndex = 6
        for (index, layer) in harness.layerStack.layers.enumerated() where index % 3 == 0 {
            harness.fill(layer, red: 0.5, green: 0.4, blue: 0.3, alpha: 0.5)
        }
        harness.select(.oil)
        harness.viewModel.brushSize = 60
        let device = harness.context.device
        print(String(format: "BENCHMARK large-canvas (%@) | 8192² × 12 layers | %d MB allocated", build, device.currentAllocatedSize / 1_048_576))

        func gpuMilliseconds(_ body: () -> Void) -> (call: Double, gpu: Double) {
            var call = 0.0
            let gpu = milliseconds {
                call = milliseconds(body)
                let fence = harness.context.commandQueue.makeCommandBuffer()!
                fence.commit()
                fence.waitUntilCompleted()
            }
            return (call, gpu)
        }

        // Idle frames: nothing has changed since the last one
        harness.renderFrame()
        var idle: [Double] = []
        for _ in 0..<5 { idle.append(milliseconds { harness.renderFrameAsTheAppWould() }) }
        let thumbnail = milliseconds { _ = harness.renderer.generateThumbnail(for: harness.drawingLayer) }
        print(String(format: "BENCHMARK large-canvas idle frame (%@) | %6.2f ms | full recomposite %6.2f ms | thumbnail %6.2f ms",
                     build, median(idle), milliseconds { harness.renderFrame() }, thumbnail))

        // Frames while drawing, and the commit
        var x = 1000.0, timestamp = 0.0
        func nextPoint() -> StrokePoint {
            x += 25; timestamp += 1.0 / 120
            return StrokePoint(position: CGPoint(x: x, y: 4000 + 300 * sin(x / 500)), pressure: 0.8, tiltX: 0, tiltY: 0, rotation: 0, timestamp: timestamp)
        }
        harness.renderer.beginStroke()
        harness.viewModel.beginStroke(point: nextPoint())
        var drawing: [Double] = []
        for _ in 0..<20 {
            harness.viewModel.continueStroke(point: nextPoint())
            drawing.append(milliseconds { harness.renderFrame() })
        }
        let commit = gpuMilliseconds {
            harness.renderer.finalizeStroke()
            harness.viewModel.endStroke()
        }
        print(String(format: "BENCHMARK large-canvas drawing frame (%@) | %6.2f ms | stroke commit call %6.2f ms gpu %6.2f ms",
                     build, median(drawing), commit.call, commit.gpu))

        // Undo steps: a selection changes no pixels, a fill changes one layer
        let selection = gpuMilliseconds { harness.viewModel.saveUndoSnapshot(renderer: harness.renderer, description: "Select", changing: .nothing) }
        harness.viewModel.undoManager.waitForPendingWork()
        let fill = gpuMilliseconds {
            harness.viewModel.saveUndoSnapshot(renderer: harness.renderer, description: "Fill", changing: .layer(harness.drawingLayer))
        }
        harness.viewModel.undoManager.waitForPendingWork()
        print(String(format: "BENCHMARK large-canvas undo step (%@) | selection call %6.2f ms gpu %7.2f ms | fill call %6.2f ms gpu %7.2f ms | history %d MB",
                     build, selection.call, selection.gpu, fill.call, fill.gpu, harness.viewModel.undoManager.textureBytes / 1_048_576))
    }

    /// Cost of a whole-stack undo snapshot, which actions other than strokes still take
    /// (layer changes, fills, pastes, selections).
    /// `call` is how long the caller is blocked; `gpu` is until the copies have finished.
    func testWholeStackUndoSnapshot() throws {
        for layerCount in [2, 8] {
            let harness = try EngineHarness(width: 2048, height: 2048)
            while harness.layerStack.layers.count < layerCount { try harness.addLayer() }

            var call: [Double] = []
            var gpu: [Double] = []
            for _ in 0..<5 {
                gpu.append(milliseconds {
                    call.append(milliseconds {
                        harness.viewModel.saveUndoSnapshot(renderer: harness.renderer, description: "Benchmark")
                    })
                    // The snapshot blits don't wait; an empty buffer behind them tells us when they finish.
                    let fence = harness.context.commandQueue.makeCommandBuffer()!
                    fence.commit()
                    fence.waitUntilCompleted()
                })
            }
            let megabytes = layerCount * 2048 * 2048 * 8 / (1024 * 1024)
            print(String(format: "BENCHMARK whole-stack-snapshot (%@) | %d layers at 2048² | call %6.2f ms | gpu %6.2f ms | %d MB per undo step",
                         build, layerCount, median(call), median(gpu), megabytes))
        }
    }
}
