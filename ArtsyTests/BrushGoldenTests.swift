import XCTest
@testable import Artsy

/// Golden-image tests: render fixed strokes through the real engine and compare with the
/// PNGs in `ArtsyTests/Golden/`. They catch unintended changes to how brushes look.
///
/// Re-record after an intended change:
///
///     TEST_RUNNER_ARTSY_RECORD_GOLDENS=1 xcodebuild test -project Artsy.xcodeproj -scheme Artsy -destination 'platform=macOS'
///
/// The grain shaders hash pixel positions through `sin`, so goldens are only expected to
/// match on the GPU family they were recorded on.
final class BrushGoldenTests: XCTestCase {
    private let ink = StrokeColor(red: 0.12, green: 0.33, blue: 0.70, alpha: 1)

    private func slug(_ name: String) -> String {
        name.lowercased()
            .folding(options: .diacriticInsensitive, locale: nil)
            .replacingOccurrences(of: " ", with: "-")
    }

    func testEveryBrush() throws {
        for brush in BrushDescriptor.allDefaults {
            let harness = try EngineHarness()
            harness.select(brush)
            harness.viewModel.currentColor = ink
            StrokeFixtures.brushSheet.forEach { harness.draw($0) }
            Golden.assertMatches(harness.displayed(), named: "brush-\(slug(brush.name))")
        }
    }

    /// Light paint over dark: the case the default white canvas hides.
    func testSoftBrushesOverDarkPaint() throws {
        let harness = try EngineHarness()
        harness.fill(harness.backgroundLayer, red: 0.08, green: 0.08, blue: 0.10)
        harness.viewModel.currentColor = StrokeColor(red: 1.0, green: 0.93, blue: 0.75, alpha: 1)
        for (row, brush) in [BrushDescriptor.softRound, .airbrush, .watercolor].enumerated() {
            harness.select(brush)
            let y = CGFloat(230 - row * 85)
            harness.draw(StrokeFixtures.line(from: CGPoint(x: 40, y: y), to: CGPoint(x: 470, y: y), pressure: 0.2...1.0))
        }
        Golden.assertMatches(harness.displayed(), named: "soft-brushes-over-dark")
    }

    func testEraser() throws {
        let harness = try EngineHarness()
        harness.viewModel.currentColor = ink
        harness.viewModel.brushSize = 44
        for y in stride(from: 50, through: 240, by: 38) {
            harness.draw(StrokeFixtures.line(from: CGPoint(x: 30, y: CGFloat(y)), to: CGPoint(x: 482, y: CGFloat(y)), pressure: 1...1))
        }

        harness.select(.eraser)
        harness.draw(StrokeFixtures.line(from: CGPoint(x: 60, y: 30), to: CGPoint(x: 200, y: 260), pressure: 0.1...1.0))
        harness.draw(StrokeFixtures.wave(from: CGPoint(x: 220, y: 150), length: 260, amplitude: 60, cycles: 2))
        harness.viewModel.brushOpacity = 0.5
        harness.draw(StrokeFixtures.line(from: CGPoint(x: 240, y: 40), to: CGPoint(x: 480, y: 40), pressure: 1...1))
        Golden.assertMatches(harness.displayed(), named: "eraser")
    }

    func testStrokeOpacity() throws {
        let harness = try EngineHarness()
        harness.viewModel.brushSize = 26
        for (index, opacity) in [Float(1.0), 0.75, 0.5, 0.25].enumerated() {
            harness.viewModel.brushOpacity = opacity
            harness.viewModel.currentColor = index % 2 == 0 ? ink : StrokeColor(red: 0.85, green: 0.25, blue: 0.15, alpha: 1)
            let y = CGFloat(230 - index * 55)
            harness.draw(StrokeFixtures.wave(from: CGPoint(x: 30, y: y), length: 452, amplitude: 45, cycles: 2.5))
        }
        Golden.assertMatches(harness.displayed(), named: "stroke-opacity")
    }

    func testSymmetry() throws {
        for (name, mode) in [("quad", SymmetryMode.quad), ("radial-6", .radial(6))] {
            let harness = try EngineHarness(width: 320, height: 320)
            harness.select(.inkBrush)
            harness.viewModel.currentColor = ink
            harness.viewModel.symmetryMode = mode
            harness.draw(StrokeFixtures.spiral(center: CGPoint(x: 215, y: 190), radius: 6...48, turns: 1.5, pressure: 0.8))
            harness.draw(StrokeFixtures.line(from: CGPoint(x: 300, y: 250), to: CGPoint(x: 170, y: 170), pressure: 0.1...0.9))
            Golden.assertMatches(harness.displayed(), named: "symmetry-\(name)")
        }
    }

    func testSmoothingModes() throws {
        for mode in SmoothingMode.allCases {
            let harness = try EngineHarness(width: 512, height: 160)
            harness.select(.inkBrush)
            harness.viewModel.brushSize = 8
            harness.viewModel.smoothingMode = mode
            harness.viewModel.smoothingStrength = 0.6
            harness.draw(StrokeFixtures.shaky(from: CGPoint(x: 30, y: 110), to: CGPoint(x: 482, y: 110), jitter: 4))
            harness.draw(StrokeFixtures.zigzag(from: CGPoint(x: 30, y: 20), length: 452, height: 50, teeth: 9))
            Golden.assertMatches(harness.displayed(), named: "smoothing-\(slug(mode.rawValue))")
        }
    }

    func testLayerBlendModes() throws {
        for mode in LayerBlendMode.allCases {
            let harness = try EngineHarness(width: 320, height: 200)
            harness.viewModel.brushSize = 34

            // Lower layer: three bands, light to dark.
            let bands: [StrokeColor] = [
                StrokeColor(red: 0.95, green: 0.85, blue: 0.35, alpha: 1),
                StrokeColor(red: 0.30, green: 0.65, blue: 0.45, alpha: 1),
                StrokeColor(red: 0.20, green: 0.15, blue: 0.40, alpha: 1),
            ]
            for (index, colour) in bands.enumerated() {
                harness.viewModel.currentColor = colour
                let y = CGFloat(160 - index * 60)
                harness.draw(StrokeFixtures.line(from: CGPoint(x: 20, y: y), to: CGPoint(x: 300, y: y), pressure: 1...1))
            }

            // Upper layer at 80%, blended: soft strokes crossing the bands and the bare paper.
            try harness.addLayer(blendMode: mode, opacity: 0.8)
            harness.select(.softRound)
            harness.viewModel.brushSize = 50
            for (index, colour) in [StrokeColor(red: 0.85, green: 0.25, blue: 0.15, alpha: 1), ink,
                                    StrokeColor(red: 0.55, green: 0.55, blue: 0.55, alpha: 1)].enumerated() {
                harness.viewModel.currentColor = colour
                let x = CGFloat(70 + index * 90)
                harness.draw(StrokeFixtures.line(from: CGPoint(x: x, y: 10), to: CGPoint(x: x, y: 190), pressure: 1...1))
            }
            Golden.assertMatches(harness.displayed(), named: "blend-\(mode.rawValue)")
        }
    }

    /// Replays any real pen recordings dropped into `ArtsyTests/Recordings/` (see `StrokeRecorder`).
    func testRecordedSessions() throws {
        let folder = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Recordings")
        let files = ((try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.pathExtension == "json" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        try XCTSkipIf(files.isEmpty, "No recordings in \(folder.path)")

        for file in files {
            let recording = try JSONDecoder().decode(StrokeRecording.self, from: Data(contentsOf: file))
            let harness = try EngineHarness(width: recording.canvasWidth, height: recording.canvasHeight)
            recording.strokes.forEach { harness.draw($0) }
            Golden.assertMatches(harness.displayed(), named: "recording-\(slug(file.deletingPathExtension().lastPathComponent))")
        }
    }
}
