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

    /// Each frame the view tells the stroke the pen is still there. That only counts for a
    /// frame no sample arrived before, and it is recorded like any other sample so a
    /// replay rests for just as long.
    func testHoldingThePenIsFedToTheStrokeAndRecorded() throws {
        let harness = try EngineHarness(width: 100, height: 100)
        let recorder = StrokeRecorder(canvasSize: harness.viewModel.canvasSize, fileURL: nil)
        harness.viewModel.recorder = recorder
        let viewModel = harness.viewModel

        func sample(_ x: CGFloat, _ t: Double) -> StrokePoint {
            StrokePoint(position: CGPoint(x: x, y: 50), pressure: 0.5, tiltX: 0, tiltY: 0, rotation: 0, timestamp: t)
        }
        harness.renderer.beginStroke()
        viewModel.beginStroke(point: sample(10, 100))
        viewModel.continueStroke(point: sample(20, 100.005))
        viewModel.holdStroke(at: 100.006)   // a sample arrived before this frame: not a rest
        XCTAssertEqual(viewModel.activePath?.samples.count, 2)
        XCTAssertEqual(viewModel.restSamplesInStroke, 0)
        viewModel.holdStroke(at: 100.3)
        viewModel.holdStroke(at: 100.6)
        XCTAssertEqual(viewModel.activePath?.samples.count, 2, "resting adds no points to the path")
        XCTAssertEqual(viewModel.restSamplesInStroke, 2)
        // The rests are a frame on from the sample, on its clock: 0.294 s and 0.3 s more
        XCTAssertEqual(viewModel.activePath?.holdDuration ?? 0, 0.594, accuracy: 0.0005)
        harness.renderer.finalizeStroke()
        viewModel.endStroke()

        let stroke = try XCTUnwrap(recorder.recording.strokes.first)
        XCTAssertEqual(stroke.points.count, 4, "the two holds are recorded")
        XCTAssertEqual(stroke.points.last?.time ?? 0, 0.599, accuracy: 0.0001)
        XCTAssertEqual(stroke.points.last?.x ?? 0, 20, accuracy: 0.001)

        viewModel.holdStroke(at: 101)
        XCTAssertNil(viewModel.activePath, "nothing happens once the pen is up")
    }

    /// A rest is a frame that no sample arrived before — not a sample older than the frame,
    /// which on an XP-Pen is every sample: its driver delivers them 20–70 ms late. (Two
    /// releases took the rests that made for repeated events, and filtered this view's
    /// input for copies that never came.) And a rest is stamped on the pen's clock, so the
    /// real sample after it is not in its past.
    func testAFrameWithASampleBeforeItIsNoRestHoweverLateTheSampleWas() throws {
        let harness = try EngineHarness(width: 100, height: 100)
        let recorder = StrokeRecorder(canvasSize: harness.viewModel.canvasSize, fileURL: nil)
        harness.viewModel.recorder = recorder
        let viewModel = harness.viewModel

        func sample(_ x: CGFloat, _ t: Double) -> StrokePoint {
            StrokePoint(position: CGPoint(x: x, y: 50), pressure: 0.5, tiltX: 0, tiltY: 0, rotation: 0, timestamp: t)
        }
        harness.renderer.beginStroke()
        viewModel.beginStroke(point: sample(10, 100))
        // Samples stamped 4 ms apart, each in hand 40 ms later; frames 16 ms apart
        viewModel.continueStroke(point: sample(11, 100.004))
        viewModel.holdStroke(at: 100.050)
        viewModel.continueStroke(point: sample(12, 100.008))
        viewModel.continueStroke(point: sample(13, 100.012))
        viewModel.holdStroke(at: 100.066)
        XCTAssertEqual(viewModel.restSamplesInStroke, 0, "the pen was moving")
        XCTAssertEqual(viewModel.activePath?.holdDuration ?? 0, 0)

        // Then it stops: two frames pass with nothing new
        viewModel.holdStroke(at: 100.082)
        viewModel.holdStroke(at: 100.098)
        XCTAssertEqual(viewModel.restSamplesInStroke, 2)
        XCTAssertEqual(viewModel.activePath?.holdDuration ?? 0, 0.032, accuracy: 0.0005, "a frame each")

        // And moves on. The sample is later than the rests: the clock never ran backwards
        viewModel.continueStroke(point: sample(14, 100.060))
        harness.renderer.finalizeStroke()
        viewModel.endStroke()
        let times = try XCTUnwrap(recorder.recording.strokes.first).points.map(\.time)
        XCTAssertEqual(times.count, 7, "five samples and two rests")
        XCTAssertEqual(times, times.sorted(), "\(times)")
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

    /// A calligraphy stroke's mirror image is thick where the original is thin: the nib
    /// goes through the mirror too.
    func testACalligraphyStrokeIsMirroredNibAndAll() throws {
        let harness = try EngineHarness(width: 300, height: 200)
        harness.select(.calligraphy)
        harness.viewModel.brushSize = 24
        harness.viewModel.symmetryMode = .horizontal
        harness.draw(StrokeFixtures.line(from: CGPoint(x: 40, y: 40), to: CGPoint(x: 130, y: 160), pressure: 1...1))
        let layer = harness.pixels(of: harness.drawingLayer.texture)
        func ink(_ xs: Range<Int>) -> Float {
            var total: Float = 0
            for y in 0..<200 { for x in xs { total += layer.at(x: x, y: y).w } }
            return total
        }
        let left = ink(0..<150), right = ink(150..<300)
        XCTAssertGreaterThan(left, 200)
        XCTAssertEqual(right, left, accuracy: left * 0.05, "the same amount of ink on each side")
    }

    /// A tablet glitch can send a sample that is not a number; no stroke can use it.
    func testSamplesThatAreNotNumbersAreDropped() throws {
        let harness = try EngineHarness(width: 64, height: 64)
        let viewModel = harness.viewModel
        viewModel.beginStroke(point: StrokePoint(position: CGPoint(x: CGFloat.nan, y: 10), pressure: 0.5,
                                                 tiltX: 0, tiltY: 0, rotation: 0, timestamp: 0))
        XCTAssertFalse(viewModel.isDrawing)

        let line = StrokeFixtures.line(from: CGPoint(x: 10, y: 10), to: CGPoint(x: 50, y: 50))
        harness.renderer.beginStroke()
        viewModel.beginStroke(point: line[0])
        viewModel.continueStroke(point: line[1])
        let count = viewModel.drawnPath?.samples.count
        viewModel.continueStroke(point: StrokePoint(position: CGPoint(x: 20, y: CGFloat.infinity), pressure: Float.nan,
                                                    tiltX: 0, tiltY: 0, rotation: 0, timestamp: 0.1))
        XCTAssertEqual(viewModel.drawnPath?.samples.count, count, "dropped")
        viewModel.continueStroke(point: line[2])
        XCTAssertEqual(viewModel.drawnPath?.samples.count, count.map { $0 + 1 }, "the next good sample is taken")
        harness.renderer.finalizeStroke()
        viewModel.endStroke()
    }

    /// Adaptive smoothing depends on the zoom, so a recording keeps it and a replay sets it.
    func testARecordedStrokeRemembersItsZoom() throws {
        let harness = try EngineHarness(width: 64, height: 64)
        harness.viewModel.transform.scale = 0.45
        let stroke = RecordedStroke(settingsFrom: harness.viewModel)
        XCTAssertEqual(stroke.zoom, 0.45)

        let other = try EngineHarness(width: 64, height: 64)
        XCTAssertTrue(stroke.applySettings(to: other.viewModel))
        XCTAssertEqual(other.viewModel.transform.scale, 0.45)

        var older = stroke
        older.zoom = nil
        other.viewModel.transform.scale = 2
        XCTAssertTrue(older.applySettings(to: other.viewModel))
        XCTAssertEqual(other.viewModel.transform.scale, 2, "an older recording leaves the zoom as it is")
    }
}
