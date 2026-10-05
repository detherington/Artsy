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

    /// Cost of the undo snapshot taken at pen down, by layer count.
    /// `call` is how long pen-down is blocked; `gpu` is until the copies have finished.
    func testUndoSnapshotAtPenDown() throws {
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
            print(String(format: "BENCHMARK undo-snapshot (%@) | %d layers at 2048² | call %6.2f ms | gpu %6.2f ms | %d MB per undo step",
                         build, layerCount, median(call), median(gpu), megabytes))
        }
    }
}
