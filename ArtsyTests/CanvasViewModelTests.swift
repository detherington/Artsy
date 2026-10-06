import XCTest
@testable import Artsy

final class CanvasViewModelTests: XCTestCase {

    func testEachBrushKeepsItsOwnSize() {
        let viewModel = CanvasViewModel(canvasSize: CGSize(width: 64, height: 64))
        // Whatever brush the saved preferences start on, use two others.
        let others = BrushDescriptor.allDefaults.filter { $0.id != viewModel.currentBrush.id }
        let first = others.first { $0.name == "Technical Pen" }!
        let second = others.first { $0.name == "Airbrush" }!

        viewModel.currentBrush = first
        XCTAssertEqual(viewModel.brushSize, first.baseSize, "a brush starts at its base size")

        viewModel.brushSize = 9
        viewModel.currentBrush = second
        XCTAssertEqual(viewModel.brushSize, second.baseSize)

        viewModel.currentBrush = first
        XCTAssertEqual(viewModel.brushSize, 9, "coming back to a brush restores the size it was left at")

        viewModel.currentBrush = .eraser
        XCTAssertEqual(viewModel.brushSize, BrushDescriptor.eraser.baseSize)
        viewModel.currentBrush = first
        XCTAssertEqual(viewModel.brushSize, 9, "switching to the eraser and back keeps the brush size")
    }

    func testEachBrushKeepsItsOwnSmoothingAmount() {
        let viewModel = CanvasViewModel(canvasSize: CGSize(width: 64, height: 64))
        let others = BrushDescriptor.allDefaults.filter { $0.id != viewModel.currentBrush.id }
        let pencil = others.first { $0.name == "Pencil" }!
        let sumiE = others.first { $0.name == "Sumi-e" }!

        viewModel.currentBrush = pencil
        XCTAssertEqual(viewModel.smoothingStrength, pencil.smoothing)
        viewModel.smoothingStrength = 0.9
        viewModel.currentBrush = sumiE
        XCTAssertEqual(viewModel.smoothingStrength, sumiE.smoothing)
        viewModel.currentBrush = pencil
        XCTAssertEqual(viewModel.smoothingStrength, 0.9)
    }

    /// With smoothing on, the stroke that lands on the layer still ends where the pen lifted.
    func testSmoothedStrokeEndsWhereThePenLifted() throws {
        for mode in [SmoothingMode.oneEuro, .movingAverage] {
            let harness = try EngineHarness(width: 300, height: 100)
            harness.viewModel.brushSize = 8
            harness.viewModel.smoothingMode = mode
            harness.viewModel.smoothingStrength = 1.0
            // A fast stroke that stops dead: the filter is well behind when the pen lifts.
            harness.draw(StrokeFixtures.line(from: CGPoint(x: 20, y: 50), to: CGPoint(x: 280, y: 50),
                                             pressure: 1...1, duration: 0.1))
            let shown = harness.displayed()
            XCTAssertLessThan(shown.at(x: 278, y: 50).x, 0.1, "\(mode.rawValue): the stroke reaches the pen-up point")
            XCTAssertEqual(shown.at(x: 290, y: 50).x, 1, accuracy: 0.01, "\(mode.rawValue): and goes no further")
        }
    }

    /// A mouse stroke eases in and out; the same samples from a pen do not.
    func testOnlyStrokesWithoutPressureAreEased() throws {
        func widthProfile(hasPressure: Bool, eases: Bool = true) throws -> (start: Float, middle: Float) {
            let harness = try EngineHarness(width: 300, height: 100)
            harness.viewModel.brushSize = 20
            harness.viewModel.easesStrokesWithoutPressure = eases
            harness.draw(StrokeFixtures.line(from: CGPoint(x: 30, y: 50), to: CGPoint(x: 270, y: 50), pressure: 0.7...0.7),
                         hasPressure: hasPressure)
            // How dark the paper is 7 px off the centre line: covered where the stroke is
            // at full width (15.8 px), bare where it has tapered.
            let shown = harness.displayed()
            return (shown.at(x: 36, y: 57).x, shown.at(x: 150, y: 57).x)
        }
        let pen = try widthProfile(hasPressure: true)
        XCTAssertLessThan(pen.start, 0.1)
        XCTAssertLessThan(pen.middle, 0.1)

        let mouse = try widthProfile(hasPressure: false)
        XCTAssertGreaterThan(mouse.start, 0.9, "tapered at the start")
        XCTAssertLessThan(mouse.middle, 0.1, "full width in the middle")

        let mouseUneased = try widthProfile(hasPressure: false, eases: false)
        XCTAssertLessThan(mouseUneased.start, 0.1, "the preference turns it off")
    }

    func testRecorderCapturesRawInputAndSettings() throws {
        let harness = try EngineHarness(width: 128, height: 128)
        let recorder = StrokeRecorder(canvasSize: harness.viewModel.canvasSize, fileURL: nil)
        harness.viewModel.recorder = recorder

        harness.select(.inkBrush)
        harness.viewModel.brushOpacity = 0.4
        harness.viewModel.smoothingMode = .lazyBrush
        harness.viewModel.symmetryMode = .radial(5)
        let input = StrokeFixtures.line(from: CGPoint(x: 10, y: 10), to: CGPoint(x: 100, y: 90), pressure: 0.2...0.9)
            .map { StrokePoint(position: $0.position, pressure: $0.pressure, tiltX: 0.25, tiltY: -0.5,
                               rotation: 30, timestamp: $0.timestamp + 5000) }
        harness.draw(input)

        XCTAssertEqual(recorder.recording.canvasWidth, 128)
        let stroke = try XCTUnwrap(recorder.recording.strokes.first)
        XCTAssertEqual(recorder.recording.strokes.count, 1)
        XCTAssertEqual(stroke.brushName, "Ink Brush")
        XCTAssertEqual(stroke.size, BrushDescriptor.inkBrush.baseSize)
        XCTAssertEqual(stroke.opacity, 0.4)
        XCTAssertEqual(stroke.smoothingMode, .lazyBrush)
        XCTAssertEqual(stroke.symmetry, "radial:5")

        // Raw points, not the lazy-brush output, with time measured from pen down.
        XCTAssertEqual(stroke.points.count, input.count)
        let last = try XCTUnwrap(stroke.points.last)
        XCTAssertEqual(last.x, 100, accuracy: 0.001)
        XCTAssertEqual(last.y, 90, accuracy: 0.001)
        XCTAssertEqual(last.pressure, 0.9, accuracy: 0.0001)
        XCTAssertEqual(last.tiltY, -0.5, accuracy: 0.0001)
        XCTAssertEqual(stroke.points[0].time, 0)
        XCTAssertEqual(last.time, 0.5, accuracy: 0.0001)
    }

    func testRecordingSurvivesJSONAndReplaysIdentically() throws {
        let original = try EngineHarness(width: 200, height: 120)
        let recorder = StrokeRecorder(canvasSize: original.viewModel.canvasSize, fileURL: nil)
        original.viewModel.recorder = recorder
        original.select(.pencil)
        original.viewModel.currentColor = StrokeColor(red: 0.6, green: 0.1, blue: 0.3, alpha: 1)
        original.viewModel.smoothingMode = .oneEuro
        original.draw(StrokeFixtures.shaky(from: CGPoint(x: 15, y: 60), to: CGPoint(x: 185, y: 60), jitter: 2))
        original.select(.eraser)
        original.draw(StrokeFixtures.line(from: CGPoint(x: 100, y: 20), to: CGPoint(x: 100, y: 100)))

        let data = try JSONEncoder().encode(recorder.recording)
        let decoded = try JSONDecoder().decode(StrokeRecording.self, from: data)
        XCTAssertEqual(decoded, recorder.recording)

        let replay = try EngineHarness(width: decoded.canvasWidth, height: decoded.canvasHeight)
        decoded.strokes.forEach { replay.draw($0) }

        let a = original.composite(), b = replay.composite()
        var worst: Float = 0
        for i in a.values.indices { worst = max(worst, abs(a.values[i] - b.values[i])) }
        // The recording rounds positions to 1/1000 px, so allow a whisker at stroke edges.
        XCTAssertLessThan(worst, 0.02)
    }

    func testSymmetryRecordingKeysRoundTrip() {
        for mode in [SymmetryMode.off, .horizontal, .vertical, .quad, .radial(2), .radial(12)] {
            XCTAssertEqual(SymmetryMode(recordingKey: mode.recordingKey), mode)
        }
    }
}
