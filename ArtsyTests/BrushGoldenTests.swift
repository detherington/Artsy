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
            // A smudge brush shows nothing on a blank layer: give it bands of paint to drag.
            if brush.smudgeSettings != nil {
                harness.select(.hardRound)
                harness.viewModel.brushSize = 70
                for (index, band) in BrushPreview.paintBands.enumerated() {
                    harness.viewModel.currentColor = band
                    let x = CGFloat(100 + 156 * index)
                    harness.draw(StrokeFixtures.line(from: CGPoint(x: x, y: 20), to: CGPoint(x: x, y: 268), pressure: 1...1))
                }
            }
            harness.select(brush)
            harness.viewModel.currentColor = ink
            StrokeFixtures.brushSheet.forEach { harness.draw($0) }
            Golden.assertMatches(harness.displayed(), named: "brush-\(slug(brush.name))")
        }
    }

    /// Thick paint lit by the display: Oil and Acrylic strokes crossing, through the display
    /// shader at full relief.
    func testThickPaintRelief() throws {
        let harness = try EngineHarness()
        harness.select(.oil)
        harness.viewModel.brushSize = 44
        harness.viewModel.currentColor = StrokeColor(red: 0.85, green: 0.55, blue: 0.15, alpha: 1)
        harness.draw(StrokeFixtures.wave(from: CGPoint(x: 30, y: 180), length: 452, amplitude: 40, cycles: 2))
        harness.select(.acrylic)
        harness.viewModel.brushSize = 36
        harness.viewModel.currentColor = StrokeColor(red: 0.2, green: 0.4, blue: 0.75, alpha: 1)
        harness.draw(StrokeFixtures.zigzag(from: CGPoint(x: 40, y: 60), length: 430, height: 160, teeth: 5))
        harness.draw(StrokeFixtures.line(from: CGPoint(x: 60, y: 250), to: CGPoint(x: 460, y: 250), pressure: 0.3...1.0))
        Golden.assertMatches(harness.shown(relief: 1), named: "thick-paint-relief")
    }

    /// Rough shapes held at the end, snapped: a circle, a rectangle, a line and a triangle,
    /// each drawn with the pen held still for a moment before lifting.
    func testShapeSnap() throws {
        let harness = try EngineHarness()
        harness.select(.technicalPen)
        harness.viewModel.brushSize = 6
        harness.viewModel.currentColor = ink
        let shapes: [[CGPoint]] = [
            StrokeFixtures.circlePositions(center: CGPoint(x: 100, y: 190), radius: 60),
            StrokeFixtures.polygonPositions([CGPoint(x: 200, y: 130), CGPoint(x: 340, y: 140),
                                             CGPoint(x: 335, y: 250), CGPoint(x: 195, y: 240)]),
            (0...80).map { CGPoint(x: 380 + CGFloat($0) * 1.3, y: 120 + CGFloat($0) * 1.8) },
            StrokeFixtures.polygonPositions([CGPoint(x: 60, y: 30), CGPoint(x: 240, y: 40), CGPoint(x: 150, y: 110)]),
        ]
        for (index, shape) in shapes.enumerated() {
            harness.draw(StrokeFixtures.held(StrokeFixtures.rough(shape, wobble: 8, seed: UInt64(index + 1)), for: 0.8))
        }
        Golden.assertMatches(harness.displayed(), named: "shape-snap")
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

    /// A mouse has no pressure, so its strokes are eased in and out. Brushes whose size
    /// doesn't respond to pressure (Technical Pen) stay uniform.
    func testMouseStrokes() throws {
        let harness = try EngineHarness()
        harness.viewModel.currentColor = ink
        let brushes: [BrushDescriptor] = [.hardRound, .inkBrush, .sumiE, .pencil, .softRound, .technicalPen]
        for (row, brush) in brushes.enumerated() {
            harness.select(brush)
            if brush.baseSize < 12 { harness.viewModel.brushSize = 12 }
            let y = CGFloat(262 - row * 46)
            let mouse = StrokeFixtures.wave(from: CGPoint(x: 30, y: y), length: 300, amplitude: 12, cycles: 1.5)
                .map { StrokePoint(position: $0.position, pressure: 0.7, tiltX: 0, tiltY: 0, rotation: 0, timestamp: $0.timestamp) }
            harness.draw(mouse, hasPressure: false)
            // A short flick and a click
            harness.draw(StrokeFixtures.line(from: CGPoint(x: 370, y: y - 8), to: CGPoint(x: 410, y: y + 8), duration: 0.08),
                         hasPressure: false)
            harness.draw(StrokeFixtures.dot(at: CGPoint(x: 460, y: y), pressure: 0.7), hasPressure: false)
        }
        Golden.assertMatches(harness.displayed(), named: "mouse-strokes")
    }

    /// Dry media shade with the side of the pencil when it leans over; a loaded ink brush
    /// thins as it is swept faster.
    func testDynamics() throws {
        let harness = try EngineHarness()
        harness.viewModel.currentColor = ink
        func sweep(y: CGFloat, tilt: SIMD2<Float>, speed: Double) -> [StrokePoint] {
            StrokeFixtures.line(from: CGPoint(x: 30, y: y), to: CGPoint(x: 482, y: y), pressure: 0.7...0.7, duration: 452 / speed)
                .map { StrokePoint(position: $0.position, pressure: $0.pressure, tiltX: tilt.x, tiltY: tilt.y,
                                   rotation: 0, timestamp: $0.timestamp) }
        }
        for (row, brush) in [BrushDescriptor.pencil, .graphiteStick, .chalk].enumerated() {
            harness.select(brush)
            let y = CGFloat(262 - row * 62)
            harness.draw(sweep(y: y + 14, tilt: .zero, speed: 400))                // upright
            harness.draw(sweep(y: y - 14, tilt: SIMD2(0.3, -0.85), speed: 400))    // leaning
        }
        for (row, brush) in [BrushDescriptor.inkBrush, .sumiE].enumerated() {
            harness.select(brush)
            let y = CGFloat(76 - row * 44)
            harness.draw(sweep(y: y + 10, tilt: .zero, speed: 250))     // slow
            harness.draw(sweep(y: y - 10, tilt: .zero, speed: 2500))    // fast
        }
        Golden.assertMatches(harness.displayed(), named: "dynamics")
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

    /// A session brought back from another Mac: `ARTSY_SESSION_RECORDING` names its stroke
    /// recording and `ARTSY_SESSION_DOCUMENT` the document it saved. The recording is
    /// replayed here, at each zoom in `ARTSY_SESSION_ZOOMS` (adaptive smoothing depends on
    /// it), and compared with the document's drawing layer; the replay, the saved layer and
    /// their difference are written to `ARTSY_SESSION_OUT`, and `SESSION` lines say how far
    /// apart they are.
    func testReplaysASessionFromDisk() throws {
        let environment = ProcessInfo.processInfo.environment
        guard let recordingPath = environment["ARTSY_SESSION_RECORDING"], let documentPath = environment["ARTSY_SESSION_DOCUMENT"] else {
            throw XCTSkip("set ARTSY_SESSION_RECORDING and ARTSY_SESSION_DOCUMENT")
        }
        let out = environment["ARTSY_SESSION_OUT"].map { URL(fileURLWithPath: $0) }
        let zooms = (environment["ARTSY_SESSION_ZOOMS"] ?? "1").split(separator: ",").compactMap { Double($0) }
        let recording = try JSONDecoder().decode(StrokeRecording.self, from: Data(contentsOf: URL(fileURLWithPath: recordingPath)))
        let document = try CanvasDocument.load(from: URL(fileURLWithPath: documentPath), metalContext: EngineHarness.sharedContext)
        let harness = try EngineHarness(width: recording.canvasWidth, height: recording.canvasHeight)
        let saved = harness.pixels(of: document.viewModel.layerStack.layers[document.viewModel.layerStack.activeLayerIndex].texture)
        if let out { try Golden.write(saved, to: out.appendingPathComponent("saved.png")) }

        for zoom in zooms {
            let replay = try EngineHarness(width: recording.canvasWidth, height: recording.canvasHeight)
            replay.viewModel.transform.scale = zoom   // each stroke brings its own smoothing mode
            for stroke in recording.strokes { replay.draw(stroke) }
            let drawn = replay.pixels(of: replay.drawingLayer.texture)

            // Alpha is what a drawing layer differs in; colour follows it
            var differing = 0, inkSaved: Float = 0, inkDrawn: Float = 0, worst: Float = 0
            var diff = PixelGrid(width: drawn.width, height: drawn.height, values: [Float](repeating: 1, count: drawn.values.count))
            for i in stride(from: 3, to: drawn.values.count, by: 4) {
                let d = abs(drawn.values[i] - saved.values[i])
                inkSaved += saved.values[i]; inkDrawn += drawn.values[i]; worst = max(worst, d)
                if d > 0.1 { differing += 1; diff.values[i - 3] = 1; diff.values[i - 2] = 1 - d; diff.values[i - 1] = 1 - d }
            }
            print(String(format: "SESSION zoom %.2f: %d of %d pixels differ by more than 0.1 (%.2f%%), ink drawn/saved %.3f, worst %.2f",
                         zoom, differing, drawn.width * drawn.height, Double(differing) * 100 / Double(drawn.width * drawn.height),
                         inkDrawn / max(inkSaved, 1), worst))
            if let out {
                try Golden.write(drawn, to: out.appendingPathComponent(String(format: "replay-%.2f.png", zoom)))
                try Golden.write(diff, to: out.appendingPathComponent(String(format: "diff-%.2f.png", zoom)))
            }
        }
    }
}
