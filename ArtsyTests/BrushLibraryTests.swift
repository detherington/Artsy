import XCTest
import AppKit
@testable import Artsy

final class BrushLibraryTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ArtsyBrushLibraryTests-\(UUID().uuidString)", isDirectory: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
        EngineHarness.sharedContext.brushTextures.userTextureDirectory = nil
    }

    func testDuplicatingABrushSavesACopyThatSurvivesARelaunch() throws {
        let library = BrushLibrary(directory: directory)
        XCTAssertEqual(library.userBrushes, [])
        XCTAssertEqual(library.all.count, BrushDescriptor.allDefaults.count)

        let copy = try library.duplicate(.pencil)
        XCTAssertEqual(copy.name, "Pencil copy")
        XCTAssertNotEqual(copy.id, BrushDescriptor.pencil.id)
        XCTAssertEqual(copy.rendering, BrushDescriptor.pencil.rendering)
        XCTAssertTrue(library.isUserBrush(copy))
        XCTAssertFalse(library.isUserBrush(.pencil))
        XCTAssertEqual(try library.duplicate(.pencil).name, "Pencil copy 2")
        XCTAssertEqual(try library.duplicate(copy).name, "Pencil copy 3")

        let relaunched = BrushLibrary(directory: directory)
        XCTAssertEqual(relaunched.userBrushes.map(\.name), ["Pencil copy", "Pencil copy 2", "Pencil copy 3"])
        XCTAssertEqual(relaunched.brush(named: "Pencil copy"), copy)
        XCTAssertEqual(relaunched.brush(id: copy.id), copy)
    }

    func testChangingAndRemovingAUserBrush() throws {
        let library = BrushLibrary(directory: directory)
        var brush = try library.duplicate(.chalk)
        brush.name = "Rough chalk"
        brush.baseSize = 44
        if case .stamp(var settings) = brush.rendering {
            settings.scatter = 0.3
            brush.rendering = .stamp(settings)
        }
        try library.save(brush)
        XCTAssertEqual(BrushLibrary(directory: directory).userBrushes, [brush])

        try library.remove(brush)
        XCTAssertEqual(library.userBrushes, [])
        XCTAssertEqual(BrushLibrary(directory: directory).userBrushes, [])
        try library.remove(.chalk)   // built-ins are left alone
        XCTAssertEqual(library.all.count, BrushDescriptor.allDefaults.count)
    }

    func testBrushFilesAreReadableJSON() throws {
        var brush = BrushDescriptor(copying: .oil, id: UUID(), name: "Scanned oil")
        brush.rendering = .stamp(StampSettings(
            tip: .image("my tip.png"), spacing: 0.1, flow: 0.5,
            grain: .init(mode: .multiply, texture: .image("canvas.png"), attachment: .canvas, scale: 1, depth: 0.5)
        ))
        let library = BrushLibrary(directory: directory)
        let file = directory.appendingPathComponent("scanned.artsybrush")
        try library.export(brush, to: file)

        let json = try String(contentsOf: file, encoding: .utf8)
        XCTAssertTrue(json.contains("\"format\" : 1"))
        XCTAssertTrue(json.contains("\"tip\" : \"image:my tip.png\""), "images are named in plain strings")
        XCTAssertTrue(json.contains("\"texture\" : \"image:canvas.png\""))
        XCTAssertTrue(json.contains("\"name\" : \"Scanned oil\""))

        let imported = try library.importBrush(from: file)
        XCTAssertEqual(imported, brush, "the same brush, same id, since nothing clashed")

        let again = try library.importBrush(from: file)
        XCTAssertNotEqual(again.id, brush.id, "importing it twice makes a second brush")
        XCTAssertEqual(again.name, "Scanned oil copy")
    }

    func testImportingATipImageAndPaintingWithIt() throws {
        let library = BrushLibrary(directory: directory)

        // A square tip, as a PNG with alpha: a 64 px image that is opaque in the middle 48 px
        let size = 64
        var rgba = [UInt8](repeating: 0, count: size * size * 4)
        for y in 8..<56 { for x in 8..<56 { rgba[(y * size + x) * 4 + 3] = 255 } }
        let source = directory.appendingPathComponent("square tip.png")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Golden.write(PixelGrid(width: size, height: size, values: rgba.map { Float($0) / 255 }), to: source)

        let name = try library.importTexture(from: source)
        XCTAssertEqual(name, "square tip.png")
        XCTAssertEqual(library.textureNames, ["square tip.png"])
        XCTAssertEqual(try library.importTexture(from: source), "square tip 2.png", "a second import doesn't overwrite")

        var brush = BrushDescriptor(copying: .hardRound, id: UUID(), name: "Square")
        brush.rendering = .stamp(StampSettings(tip: .image(name), spacing: 0.3, flow: 1))
        EngineHarness.sharedContext.brushTextures.userTextureDirectory = library.texturesDirectory

        let harness = try EngineHarness(width: 120, height: 120)
        harness.select(brush)
        harness.viewModel.brushSize = 40
        harness.draw(StrokeFixtures.dot(at: CGPoint(x: 60, y: 60), pressure: 1))
        let shown = harness.displayed()
        XCTAssertLessThan(shown.at(x: 60, y: 60).x, 0.1, "painted in the middle")
        XCTAssertLessThan(shown.at(x: 60 + 13, y: 60 + 13).x, 0.1, "and in the corner a round tip would miss")
        XCTAssertEqual(shown.at(x: 60 + 18, y: 60 + 18).x, 1, accuracy: 0.01, "but not outside the square")
    }

    func testAMissingTipImageFallsBackToARoundTip() throws {
        EngineHarness.sharedContext.brushTextures.userTextureDirectory = directory
        var brush = BrushDescriptor(copying: .hardRound, id: UUID(), name: "Lost")
        brush.rendering = .stamp(StampSettings(tip: .image("gone.png"), spacing: 0.3, flow: 1))
        let harness = try EngineHarness(width: 120, height: 120)
        harness.select(brush)
        harness.viewModel.brushSize = 40
        harness.draw(StrokeFixtures.dot(at: CGPoint(x: 60, y: 60), pressure: 1))
        let shown = harness.displayed()
        XCTAssertLessThan(shown.at(x: 60, y: 60).x, 0.1)
        XCTAssertEqual(shown.at(x: 60 + 17, y: 60 + 17).x, 1, accuracy: 0.01, "round: the corner is bare")
    }

    func testGimpBrushesImportAsGrainOrTips() throws {
        // A 16×8 grayscale .gbr: left half white (paints), right half black
        let width = 16, height = 8
        var data = Data()
        func word(_ value: Int) { data.append(contentsOf: [UInt8(value >> 24 & 0xFF), UInt8(value >> 16 & 0xFF), UInt8(value >> 8 & 0xFF), UInt8(value & 0xFF)]) }
        word(28 + 5); word(2); word(width); word(height); word(1); data.append(contentsOf: Array("GIMP".utf8)); word(10)
        data.append(contentsOf: Array("half\0".utf8))
        for _ in 0..<height { data.append(contentsOf: [UInt8](repeating: 255, count: 8) + [UInt8](repeating: 0, count: 8)) }
        let source = directory.appendingPathComponent("half.gbr")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try data.write(to: source)

        let library = BrushLibrary(directory: directory)
        let name = try library.importTexture(from: source)
        XCTAssertEqual(name, "half.png")
        let png = try XCTUnwrap(Golden.read(library.texturesDirectory.appendingPathComponent(name)))
        XCTAssertEqual(png.width, 16)
        XCTAssertEqual(png.bytes[0], 255, "white where the brush paints")
        XCTAssertEqual(png.bytes[12 * 4], 0)

        var garbage = data
        garbage[20] = 0
        XCTAssertThrowsError(try GimpBrushFile.image(from: garbage))
    }
}
