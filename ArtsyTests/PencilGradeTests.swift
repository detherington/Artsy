import XCTest
@testable import Artsy

/// A graphite brush's grade: HB is the brush itself, harder grades stay light and fine,
/// softer ones go dark, broad and crumbly. The grade is remembered per brush and across
/// launches, and a recording keeps it.
final class PencilGradeTests: XCTestCase {
    private var savedGrades: [String: String] = [:]

    override func setUp() {
        super.setUp()
        savedGrades = AppPreferences.shared.pencilGrades
    }

    override func tearDown() {
        AppPreferences.shared.pencilGrades = savedGrades
        super.tearDown()
    }

    /// The pressure the paper's deepest valleys take, from the brush's height grain.
    private func depth(_ brush: BrushDescriptor) -> Float {
        if case .stamp(let settings) = brush.rendering, let grain = settings.grain { return grain.depth }
        XCTFail("not a grained stamp brush"); return 0
    }

    func testHBIsTheBrushAndTheGradesMoveTheRightWay() {
        XCTAssertEqual(BrushDescriptor.pencil.graded(.hb), .pencil)
        XCTAssertEqual(BrushDescriptor.hardRound.graded(.b6), .hardRound, "a brush that is not graphite has no grade")
        let graded = PencilGrade.shown.map { BrushDescriptor.pencil.graded($0) }
        for (harder, softer) in zip(graded, graded.dropFirst()) {
            XCTAssertLessThanOrEqual(harder.pressureDynamics.opacityMax, softer.pressureDynamics.opacityMax, "darker cap")
            XCTAssertLessThanOrEqual(harder.pressureDynamics.opacityMin, softer.pressureDynamics.opacityMin, "darker at a light touch")
            XCTAssertGreaterThanOrEqual(depth(harder), depth(softer), "deeper reach")
            XCTAssertLessThanOrEqual(harder.pressureDynamics.sizeMax, softer.pressureDynamics.sizeMax, "broader point")
            XCTAssertGreaterThanOrEqual(harder.hardness, softer.hardness, "softer edge")
            XCTAssertLessThanOrEqual(harder.pressureDynamics.opacityMin, harder.pressureDynamics.opacityMax, "a range that is one")
        }
        let hard = BrushDescriptor.pencil.graded(.h2), soft = BrushDescriptor.pencil.graded(.b6)
        XCTAssertGreaterThanOrEqual(depth(hard), depth(BrushDescriptor.pencil), "a hard pencil reaches no more of the paper than HB")
        XCTAssertLessThan(depth(soft), 0.7, "a soft one fills the valleys at a lighter touch")
        XCTAssertEqual(hard.id, BrushDescriptor.pencil.id, "the same brush")
        XCTAssertEqual(hard.name, BrushDescriptor.pencil.name)
    }

    /// Measured on the canvas: a hard pencil pressed fully stays grey, a soft one at the
    /// same pressure goes nearly black, and at a light touch the soft one is darker still.
    func testAHardPencilStaysLightAndASoftOneGoesDark() throws {
        func darkness(_ grade: PencilGrade, pressure: Float) throws -> Float {
            let harness = try EngineHarness(width: 240, height: 80)
            harness.select(.pencil)
            harness.viewModel.brushSize = 12
            harness.viewModel.currentColor = .black
            harness.viewModel.pencilGrade = grade
            harness.draw(StrokeFixtures.line(from: CGPoint(x: 20, y: 40), to: CGPoint(x: 220, y: 40), pressure: pressure...pressure))
            let layer = harness.pixels(of: harness.drawingLayer.texture)
            var sum: Float = 0
            for x in 60...180 { for y in 38...42 { sum += layer.at(x: x, y: y).w } }
            return sum / Float(121 * 5)
        }
        let hardFull = try darkness(.h2, pressure: 1), hbFull = try darkness(.hb, pressure: 1), softFull = try darkness(.b6, pressure: 1)
        let hardLight = try darkness(.h2, pressure: 0.3), softLight = try darkness(.b6, pressure: 0.3)
        print("SCRATCH grades: full 2H \(hardFull) HB \(hbFull) 6B \(softFull); light 2H \(hardLight) 6B \(softLight)")
        XCTAssertLessThan(hardFull, hbFull, "a hard pencil is lighter than HB pressed fully")
        XCTAssertLessThan(hbFull, softFull, "and a soft one darker")
        XCTAssertLessThan(hardFull, 0.6, "a hard pencil pressed fully stays grey: \(hardFull)")
        XCTAssertGreaterThan(softFull, 0.85, "a soft one goes nearly black: \(softFull)")
        XCTAssertLessThan(hardLight, softLight, "and at a light touch the soft one is darker")
        XCTAssertLessThan(softLight, softFull * 0.85, "but still lighter than pressed fully: \(softLight) against \(softFull)")
    }

    func testTheGradeIsRememberedPerBrushAndAcrossLaunches() {
        let prefs = AppPreferences.shared
        prefs.pencilGrades = [:]
        let viewModel = CanvasViewModel(canvasSize: CGSize(width: 64, height: 64))
        viewModel.recorder = nil
        viewModel.currentBrush = .pencil
        XCTAssertEqual(viewModel.pencilGrade, .hb)
        viewModel.pencilGrade = .b2
        viewModel.currentBrush = .graphiteStick
        XCTAssertEqual(viewModel.pencilGrade, .hb, "the stick has its own grade")
        viewModel.pencilGrade = .h
        viewModel.currentBrush = .pencil
        XCTAssertEqual(viewModel.pencilGrade, .b2, "the pencil kept its grade")
        XCTAssertEqual(prefs.pencilGrades[BrushDescriptor.pencil.id.uuidString], "2B", "and it is saved")

        // Another launch
        let again = CanvasViewModel(canvasSize: CGSize(width: 64, height: 64))
        again.recorder = nil
        again.currentBrush = .graphiteStick
        XCTAssertEqual(again.pencilGrade, .h)
        again.currentBrush = .pencil
        XCTAssertEqual(again.pencilGrade, .b2)
        again.pencilGrade = .hb
        XCTAssertNil(prefs.pencilGrades[BrushDescriptor.pencil.id.uuidString], "HB is the default and is not kept")
    }

    func testARecordedStrokeKeepsItsGrade() throws {
        let viewModel = CanvasViewModel(canvasSize: CGSize(width: 64, height: 64))
        viewModel.recorder = nil
        viewModel.remembersGrades = false
        viewModel.currentBrush = .pencil
        viewModel.pencilGrade = .b4
        let stroke = RecordedStroke(settingsFrom: viewModel)
        XCTAssertEqual(stroke.grade, "4B")
        let back = try JSONDecoder().decode(RecordedStroke.self, from: try JSONEncoder().encode(stroke))
        let other = CanvasViewModel(canvasSize: CGSize(width: 64, height: 64))
        other.recorder = nil
        other.remembersGrades = false
        XCTAssertTrue(back.applySettings(to: other))
        XCTAssertEqual(other.pencilGrade, .b4)

        // A recording from before grades, or of another brush, puts the grade at HB
        var older = stroke
        older.grade = nil
        other.pencilGrade = .b6
        XCTAssertTrue(older.applySettings(to: other))
        XCTAssertEqual(other.pencilGrade, .hb)
        viewModel.currentBrush = .hardRound
        XCTAssertNil(RecordedStroke(settingsFrom: viewModel).grade, "no grade for a brush that is not graphite")
    }
}
