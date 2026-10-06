import XCTest
import AppKit
import Compression
@testable import Artsy

/// Photoshop and Procreate brush files, built in the tests from the formats' descriptions.
final class BrushImportTests: XCTestCase {
    private var directory: URL!
    private var library: BrushLibrary!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ArtsyBrushImportTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        library = BrushLibrary(directory: directory)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
        EngineHarness.sharedContext.brushTextures.userTextureDirectory = nil
    }

    // MARK: - Byte builders

    private func be16(_ v: Int) -> [UInt8] { [UInt8(v >> 8 & 0xFF), UInt8(v & 0xFF)] }
    private func be32(_ v: Int) -> [UInt8] { [UInt8(v >> 24 & 0xFF), UInt8(v >> 16 & 0xFF), UInt8(v >> 8 & 0xFF), UInt8(v & 0xFF)] }
    private func le16(_ v: Int) -> [UInt8] { [UInt8(v & 0xFF), UInt8(v >> 8 & 0xFF)] }
    private func le32(_ v: Int) -> [UInt8] { [UInt8(v & 0xFF), UInt8(v >> 8 & 0xFF), UInt8(v >> 16 & 0xFF), UInt8(v >> 24 & 0xFF)] }

    /// A tip as Photoshop stores it: grey, black where it paints. Here a 16 × 8 tip that paints
    /// its left half.
    private var tipPixels: [UInt8] {
        (0..<8).flatMap { _ in [UInt8](repeating: 0, count: 8) + [UInt8](repeating: 255, count: 8) }
    }

    /// PackBits rows: each row is "repeat 0 eight times, repeat 255 eight times" = 4 bytes.
    private var tipPackBits: [UInt8] {
        let row: [UInt8] = [UInt8(bitPattern: -7), 0, UInt8(bitPattern: -7), 255]
        return (0..<8).flatMap { _ in be16(row.count) } + (0..<8).flatMap { _ in row }
    }

    private func abrVersion2(name: String, compressed: Bool) -> Data {
        var brush: [UInt8] = []
        brush += be32(0) + be16(25)                                   // misc, spacing
        let utf16 = Array(name.utf16)
        brush += be32(utf16.count) + utf16.flatMap { be16(Int($0)) } // name, UCS-2
        brush += [1]                                                   // antialiasing
        brush += be16(0) + be16(0) + be16(8) + be16(16)                // short bounds
        brush += be32(0) + be32(0) + be32(8) + be32(16)                // long bounds
        brush += be16(8) + [compressed ? 1 : 0]                        // depth, compression
        brush += compressed ? tipPackBits : tipPixels
        var file: [UInt8] = be16(2) + be16(2)                          // version 2, two brushes
        file += be16(1) + be32(4) + [0, 0, 0, 0]                        // a computed brush, skipped
        file += be16(2) + be32(brush.count) + brush
        return Data(file)
    }

    private func abrVersion6(subversion: Int) -> Data {
        var brush: [UInt8] = [UInt8](repeating: 0x41, count: 37)       // key
        brush += [UInt8](repeating: 0, count: subversion == 1 ? 10 : 264)
        brush += be32(0) + be32(0) + be32(8) + be32(16) + be16(8) + [0] + tipPixels
        var entry = be32(brush.count) + brush
        while entry.count % 4 != 0 { entry.append(0) }
        let desc: [UInt8] = Array("8BIM".utf8) + Array("desc".utf8) + be32(3) + [1, 2, 3]
        let samp: [UInt8] = Array("8BIM".utf8) + Array("samp".utf8) + be32(entry.count) + entry
        return Data(be16(6) + be16(subversion) + desc + samp)
    }

    /// A ZIP with stored entries: enough for a Procreate brush.
    private func zip(_ files: [(String, Data)]) -> Data {
        var out: [UInt8] = []
        var central: [UInt8] = []
        for (name, data) in files {
            let nameBytes = Array(name.utf8)
            let offset = out.count
            out += le32(0x04034b50) + le16(20) + le16(0) + le16(0) + le16(0) + le16(0) + le32(0)
                + le32(data.count) + le32(data.count) + le16(nameBytes.count) + le16(0) + nameBytes + Array(data)
            central += le32(0x02014b50) + le16(20) + le16(20) + le16(0) + le16(0) + le16(0) + le16(0) + le32(0)
                + le32(data.count) + le32(data.count) + le16(nameBytes.count) + le16(0) + le16(0) + le16(0) + le16(0)
                + le32(0) + le32(offset) + nameBytes
        }
        let centralOffset = out.count
        out += central
        out += le32(0x06054b50) + le16(0) + le16(0) + le16(files.count) + le16(files.count)
            + le32(central.count) + le32(centralOffset) + le16(0)
        return Data(out)
    }

    private func greyPNG(width: Int, height: Int, _ pixel: (Int, Int) -> Float) throws -> Data {
        var values: [Float] = []
        for y in 0..<height { for x in 0..<width { let v = pixel(x, y); values += [v, v, v, 1] } }
        let url = directory.appendingPathComponent("tmp-\(UUID().uuidString).png")
        try Golden.write(PixelGrid(width: width, height: height, values: values), to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        return try Data(contentsOf: url)
    }

    // MARK: - Photoshop

    func testPhotoshopTipsAreReadFromOldAndNewFiles() throws {
        for (label, data) in [("v2 raw", abrVersion2(name: "Splat", compressed: false)),
                              ("v2 PackBits", abrVersion2(name: "Splat", compressed: true)),
                              ("v6.1", abrVersion6(subversion: 1)), ("v6.2", abrVersion6(subversion: 2))] {
            let tips = try PhotoshopBrushFile.tips(in: data)
            XCTAssertEqual(tips.count, 1, label)
            let tip = try XCTUnwrap(tips.first, label)
            XCTAssertEqual(tip.width, 16, label)
            XCTAssertEqual(tip.height, 8, label)
            XCTAssertEqual(tip.coverage[0], 255, "\(label): black in the file paints")
            XCTAssertEqual(tip.coverage[12], 0, "\(label): white in the file does not")
            XCTAssertEqual(tip.coverage.count, 128, label)
            XCTAssertEqual(tip.name, label.hasPrefix("v2") ? "Splat" : nil, label)
        }
        XCTAssertThrowsError(try PhotoshopBrushFile.tips(in: Data([0, 42, 0, 1])))
        XCTAssertThrowsError(try PhotoshopBrushFile.tips(in: Data(abrVersion2(name: "x", compressed: true).prefix(40))))
    }

    func testImportingAPhotoshopFileMakesABrushPerTip() throws {
        let file = directory.appendingPathComponent("splats.abr")
        try abrVersion2(name: "Splat", compressed: true).write(to: file)
        let brushes = try library.importBrushes(from: file)
        XCTAssertEqual(brushes.map(\.name), ["Splat"])
        XCTAssertEqual(library.textureNames, ["splats.png"])
        guard case .stamp(let settings) = brushes[0].rendering, case .image(let tip) = settings.tip else {
            return XCTFail("a stamp brush using the imported tip")
        }
        XCTAssertEqual(tip, "splats.png")

        // The tip paints on the left of its image and not on the right
        EngineHarness.sharedContext.brushTextures.userTextureDirectory = library.texturesDirectory
        let harness = try EngineHarness(width: 120, height: 120)
        harness.select(brushes[0])
        harness.viewModel.brushSize = 40
        harness.draw(StrokeFixtures.dot(at: CGPoint(x: 60, y: 60), pressure: 1))
        let shown = harness.displayed()
        XCTAssertLessThan(shown.at(x: 50, y: 60).x, 0.1)
        XCTAssertEqual(shown.at(x: 70, y: 60).x, 1, accuracy: 0.01)
    }

    // MARK: - Procreate

    func testProcreateBrushAndSetAreRead() throws {
        let shape = try greyPNG(width: 32, height: 32) { x, y in hypot(Float(x) - 16, Float(y) - 16) < 12 ? 1 : 0 }
        let grain = try greyPNG(width: 16, height: 16) { x, _ in Float(x) / 15 }

        let single = zip([("Shape.png", shape), ("Grain.png", grain), ("Brush.archive", Data([0]))])
        let one = try ProcreateBrushFile.brushes(in: single, fileName: "Scratchy")
        XCTAssertEqual(one.map(\.name), ["Scratchy"])
        XCTAssertNotNil(one[0].shape)
        XCTAssertNotNil(one[0].grain)

        let set = zip([("brushset.plist", Data([0])),
                       ("Inks/Pen.brush/Shape.png", shape), ("Inks/Pen.brush/Brush.archive", Data([0])),
                       ("Inks/Wash.brush/Grain.png", grain)])
        let many = try ProcreateBrushFile.brushes(in: set, fileName: "Inks")
        XCTAssertEqual(many.map(\.name), ["Pen", "Wash"])
        XCTAssertNil(many[1].shape)

        XCTAssertThrowsError(try ProcreateBrushFile.brushes(in: zip([("readme.txt", Data([1]))]), fileName: "x"))
        XCTAssertThrowsError(try ProcreateBrushFile.brushes(in: Data([1, 2, 3]), fileName: "x"))
    }

    func testImportingAProcreateBrushUsesItsShapeAndGrain() throws {
        let shape = try greyPNG(width: 32, height: 32) { x, y in hypot(Float(x) - 16, Float(y) - 16) < 12 ? 1 : 0 }
        let grain = try greyPNG(width: 16, height: 16) { x, _ in Float(x) / 15 }
        let file = directory.appendingPathComponent("Scratchy.brush")
        try zip([("Shape.png", shape), ("Grain.png", grain)]).write(to: file)

        let brushes = try library.importBrushes(from: file)
        XCTAssertEqual(brushes.map(\.name), ["Scratchy"])
        XCTAssertEqual(library.textureNames, ["Scratchy grain.png", "Scratchy shape.png"])
        guard case .stamp(let settings) = brushes[0].rendering else { return XCTFail("a stamp brush") }
        XCTAssertEqual(settings.tip, .image("Scratchy shape.png"))
        XCTAssertEqual(settings.grain?.texture, .image("Scratchy grain.png"))

        // White in the shape paints: the tip is the disc, not its surround
        EngineHarness.sharedContext.brushTextures.userTextureDirectory = library.texturesDirectory
        let harness = try EngineHarness(width: 120, height: 120)
        harness.select(brushes[0])
        harness.viewModel.brushSize = 48
        harness.draw(StrokeFixtures.dot(at: CGPoint(x: 60, y: 60), pressure: 1))
        let shown = harness.displayed()
        XCTAssertLessThan(shown.at(x: 60, y: 60).x, 0.6, "painted in the middle (the grain tints it)")
        XCTAssertEqual(shown.at(x: 60 + 22, y: 60 + 22).x, 1, accuracy: 0.01, "the corner of the image is bare")

        try library.importBrushes(from: file)
        XCTAssertEqual(library.userBrushes.map(\.name), ["Scratchy", "Scratchy copy"], "importing again adds a copy")
    }

    // MARK: - ZIP

    func testZipReaderHandlesStoredAndDeflatedEntries() throws {
        // A deflated entry, compressed the way zip does (raw deflate, no zlib header)
        let text = Array("hello hello hello".utf8)
        var deflated = [UInt8](repeating: 0, count: 64)
        let deflatedCount = deflated.withUnsafeMutableBufferPointer { out in
            text.withUnsafeBufferPointer { input in
                compression_encode_buffer(out.baseAddress!, 64, input.baseAddress!, text.count, nil, COMPRESSION_ZLIB)
            }
        }
        deflated = Array(deflated.prefix(deflatedCount))
        XCTAssertGreaterThan(deflatedCount, 0)
        var out: [UInt8] = []
        let name = Array("greeting.txt".utf8)
        out += le32(0x04034b50) + le16(20) + le16(0) + le16(8) + le16(0) + le16(0) + le32(0)
            + le32(deflated.count) + le32(17) + le16(name.count) + le16(0) + name + deflated
        var central: [UInt8] = le32(0x02014b50) + le16(20) + le16(20) + le16(0) + le16(8) + le16(0) + le16(0) + le32(0)
            + le32(deflated.count) + le32(17) + le16(name.count) + le16(0) + le16(0) + le16(0) + le16(0) + le32(0) + le32(0) + name
        let centralOffset = out.count
        out += central
        out += le32(0x06054b50) + le16(0) + le16(0) + le16(1) + le16(1) + le32(central.count) + le32(centralOffset) + le16(0)
        central.removeAll()

        let archive = try ZipArchive(data: Data(out))
        XCTAssertEqual(archive.entries.map(\.name), ["greeting.txt"])
        XCTAssertEqual(String(decoding: try XCTUnwrap(archive.contents(of: "greeting.txt")), as: UTF8.self), "hello hello hello")
        XCTAssertNil(try archive.contents(of: "missing"))
    }

    /// A sample record of size zero would never move the reader on.
    func testADamagedPhotoshopFileIsRefusedNotLoopedOver() {
        let samp: [UInt8] = Array("8BIM".utf8) + Array("samp".utf8) + be32(8) + be32(0) + be32(0)
        XCTAssertThrowsError(try PhotoshopBrushFile.tips(in: Data(be16(6) + be16(2) + samp)))
    }

    /// A brush file can say anything; the engine divides by some of it.
    func testBrushFileValuesAreKeptWhereTheEngineCanUseThem() throws {
        var brush = BrushDescriptor.oil
        guard case .stamp(var settings) = brush.rendering else { return XCTFail("Oil is a stamp brush") }
        settings.spacing = 0
        settings.flow = 3
        settings.impasto = .init(thickness: -1)
        brush.rendering = .stamp(settings)
        brush.opacity = 7
        brush.hardness = -2
        brush.baseSize = 0

        let decoded = try JSONDecoder().decode(BrushDescriptor.self, from: JSONEncoder().encode(brush))
        guard case .stamp(let kept) = decoded.rendering else { return XCTFail("still a stamp brush") }
        XCTAssertEqual(kept.spacing, 0.01)
        XCTAssertEqual(kept.flow, 1)
        XCTAssertEqual(kept.impasto?.thickness, 0)
        XCTAssertEqual(decoded.opacity, 1)
        XCTAssertEqual(decoded.hardness, 0)
        XCTAssertEqual(decoded.baseSize, 1)

        // And a tap with the values as they came still lays a dot rather than trapping
        let harness = try EngineHarness(width: 64, height: 64)
        harness.select(brush)
        harness.viewModel.brushSize = 20
        harness.draw(StrokeFixtures.dot(at: CGPoint(x: 32, y: 32)))
        XCTAssertGreaterThan(harness.pixels(of: harness.drawingLayer.texture).at(x: 32, y: 32).w, 0.1)
    }

    /// A deflated entry whose header promises gigabytes is not believed.
    func testAZipEntryClaimingGigabytesIsRefused() throws {
        let name = Array("Shape.png".utf8), payload: [UInt8] = [1, 2, 3], claimed = 0xFFFF_FFF0
        var out: [UInt8] = le32(0x04034b50) + le16(20) + le16(0) + le16(8) + le16(0) + le16(0) + le32(0)
            + le32(payload.count) + le32(claimed) + le16(name.count) + le16(0) + name + payload
        let centralOffset = out.count
        let central: [UInt8] = le32(0x02014b50) + le16(20) + le16(20) + le16(0) + le16(8) + le16(0) + le16(0) + le32(0)
            + le32(payload.count) + le32(claimed) + le16(name.count) + le16(0) + le16(0) + le16(0) + le16(0)
            + le32(0) + le32(0) + name
        out += central
        out += le32(0x06054b50) + le16(0) + le16(0) + le16(1) + le16(1) + le32(central.count) + le32(centralOffset) + le16(0)
        let archive = try ZipArchive(data: Data(out))
        let entry = try XCTUnwrap(archive.entries.first)
        XCTAssertThrowsError(try archive.contents(of: entry))
    }

    /// A sampled tip bigger than the texture library loads is halved until it fits.
    func testAnOversizedTipIsShrunkToFit() {
        let (pixels, width, height) = BrushLibrary.fitted([UInt8](repeating: 200, count: 9000 * 10), width: 9000, height: 10)
        XCTAssertEqual(width, 2250)
        XCTAssertEqual(height, 2)
        XCTAssertEqual(pixels.count, width * height)
        XCTAssertEqual(pixels[0], 200)
    }
}
