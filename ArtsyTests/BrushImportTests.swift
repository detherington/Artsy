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

    /// A tip as Photoshop stores it: 8-bit coverage, 255 where it paints. Here a 16 × 8 tip
    /// that paints its left half.
    private var tipPixels: [UInt8] {
        (0..<8).flatMap { _ in [UInt8](repeating: 255, count: 8) + [UInt8](repeating: 0, count: 8) }
    }

    /// PackBits rows: each row is "repeat 255 eight times, repeat 0 eight times" = 4 bytes.
    private var tipPackBits: [UInt8] {
        let row: [UInt8] = [UInt8(bitPattern: -7), 255, UInt8(bitPattern: -7), 0]
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

    /// A descriptor TEXT value: a count of UTF-16 units, null included, then the units.
    private func descriptorText(_ string: String) -> [UInt8] {
        let utf16 = Array((string + "\0").utf16)
        return be32(utf16.count) + utf16.flatMap { be16(Int($0)) }
    }

    /// Version 6: a sampled tip keyed `$BBBB…`, and a `desc` section whose brush preset
    /// "Splat" refers to it (the structure around the two texts is not what Photoshop
    /// writes, only the texts themselves).
    private func abrVersion6(subversion: Int) -> Data {
        let key = String(repeating: "B", count: 36)
        var brush: [UInt8] = [0x24] + [UInt8](repeating: 0x42, count: 36)   // "$" + key
        brush += [UInt8](repeating: 0, count: subversion == 1 ? 10 : 264)
        brush += be32(0) + be32(0) + be32(8) + be32(16) + be16(8) + [0] + tipPixels
        var entry = be32(brush.count) + brush
        while entry.count % 4 != 0 { entry.append(0) }
        let preset: [UInt8] = [1, 2, 3]
            + be32(0) + Array("Nm  TEXT".utf8) + descriptorText("Splat")
            + be32(11) + Array("sampledDataTEXT".utf8) + descriptorText(key)
            + be32(0) + Array("Nm  TEXT".utf8) + descriptorText("Not a sampled brush")
        let desc: [UInt8] = Array("8BIM".utf8) + Array("desc".utf8) + be32(preset.count) + preset
        let samp: [UInt8] = Array("8BIM".utf8) + Array("samp".utf8) + be32(entry.count) + entry
        return Data(be16(6) + be16(subversion) + desc + samp)
    }

    /// A `Brush.archive` as Procreate writes one: a keyed archive whose root is a
    /// `SilicaBrush` with the settings as plain values.
    private func brushArchive(_ values: [String: Any]) -> Data {
        let archiver = NSKeyedArchiver(requiringSecureCoding: false)
        archiver.setClassName("SilicaBrush", for: SilicaBrushStandIn.self)
        archiver.encode(SilicaBrushStandIn(values: values), forKey: "root")
        archiver.finishEncoding()
        return archiver.encodedData
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
            XCTAssertEqual(tip.coverage[0], 255, "\(label): 255 in the file paints")
            XCTAssertEqual(tip.coverage[12], 0, "\(label): 0 in the file does not")
            XCTAssertEqual(tip.coverage.count, 128, label)
            XCTAssertEqual(tip.name, "Splat", "\(label): v2 names the brush itself, v6 names it in the desc section")
        }
        XCTAssertThrowsError(try PhotoshopBrushFile.tips(in: Data([0, 42, 0, 1])))
        XCTAssertThrowsError(try PhotoshopBrushFile.tips(in: Data(abrVersion2(name: "x", compressed: true).prefix(40))))
    }

    /// A tip with nothing in it would draw nothing.
    func testABlankPhotoshopTipIsSkipped() throws {
        var file = abrVersion2(name: "Blank", compressed: false)
        // The raw 16 × 8 tip is the last 128 bytes: empty it
        file.replaceSubrange((file.count - 128)..<file.count, with: [UInt8](repeating: 0, count: 128))
        XCTAssertEqual(try PhotoshopBrushFile.tips(in: file).count, 0)
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

        // A single brush, with the signature and preview folders Procreate puts beside it
        let single = zip([("Brush.archive", Data([0])), ("Shape.png", shape), ("Grain.png", grain),
                          ("Signature/SignaturePicture.png", shape), ("QuickLook/Thumbnail.png", shape)])
        let one = try ProcreateBrushFile.brushes(in: single, fileName: "Scratchy")
        XCTAssertEqual(one.map(\.name), ["Scratchy"])
        XCTAssertNotNil(one[0].shape)
        XCTAssertNotNil(one[0].grain)
        XCTAssertNil(one[0].settings, "no readable archive")

        // A set: folders per brush in the plist's order, each with a Reset copy that is not
        // a brush of its own, and names from the archives where there are any
        let archive = brushArchive(["name": "Fine Pen", "plotSpacing": 0.0025, "paintSize": 0.02, "dynamicsPressureSize": 1.0,
                                    "dynamicsPressureOpacity": 0.0, "shapeScatter": 0.5, "shapeRotation": 1.0,
                                    "shapeRandomise": true, "dynamicsJitterSize": 0.25, "grainDepth": 0.8, "shapeInverted": false])
        let plist = try PropertyListSerialization.data(fromPropertyList: ["name": "Inks", "brushes": ["Wash", "Pen"]], format: .binary, options: 0)
        let set = zip([("brushset.plist", plist),
                       ("Pen/Shape.png", shape), ("Pen/Brush.archive", archive), ("Pen/Reset/Shape.png", shape),
                       ("Pen/Reset/Brush.archive", archive), ("Pen/QuickLook/Thumbnail.png", shape),
                       ("Pen/Sub01/Shape.png", grain), ("Pen/Sub01/Brush.archive", archive), ("Pen/Reset/Sub01/Shape.png", grain),
                       ("Wash/Grain.png", grain), ("Wash/Brush.archive", Data([0]))])
        let many = try ProcreateBrushFile.brushes(in: set, fileName: "Inks")
        XCTAssertEqual(many.map(\.name), ["Wash", "Fine Pen"], "no brush for a Reset copy or a dual brush's second half")
        XCTAssertNil(many[0].shape)
        XCTAssertNotNil(many[1].secondShape, "the dual brush's second shape")
        XCTAssertNil(many[0].secondShape)
        let settings = try XCTUnwrap(many[1].settings)
        XCTAssertEqual(settings.spacing ?? 0, 0.0025, accuracy: 1e-6)
        XCTAssertEqual(settings.pressureSize, 1)
        XCTAssertEqual(settings.pressureOpacity, 0)
        XCTAssertEqual(settings.scatter, 0.5)
        XCTAssertEqual(settings.rotation, 1)
        XCTAssertTrue(settings.randomRotation)
        XCTAssertEqual(settings.sizeJitter, 0.25)
        XCTAssertEqual(settings.grainDepth, 0.8)
        XCTAssertFalse(settings.shapeInverted)

        XCTAssertThrowsError(try ProcreateBrushFile.brushes(in: zip([("readme.txt", Data([1]))]), fileName: "x"))
        XCTAssertThrowsError(try ProcreateBrushFile.brushes(in: Data([1, 2, 3]), fileName: "x"))
    }

    func testImportingAProcreateBrushUsesItsShapeAndGrain() throws {
        // A disc on a background that is dark grey, not black, as some shapes are
        let shape = try greyPNG(width: 32, height: 32) { x, y in hypot(Float(x) - 16, Float(y) - 16) < 12 ? 1 : 0.08 }
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
        XCTAssertEqual(shown.at(x: 60 + 22, y: 60 + 22).x, 1, accuracy: 0.01, "the corner of the image is bare: its grey background is not paint")

        try library.importBrushes(from: file)
        XCTAssertEqual(library.userBrushes.map(\.name), ["Scratchy", "Scratchy copy"], "importing again adds a copy")
    }

    /// The archive's settings, where they map onto a stamp brush.
    func testImportingAProcreateBrushTakesItsSettings() throws {
        let shape = try greyPNG(width: 32, height: 32) { x, y in hypot(Float(x) - 16, Float(y) - 16) < 12 ? 1 : 0 }
        let archive = brushArchive(["name": "Fine Pen", "plotSpacing": 0.0025, "paintSize": 0.02, "dynamicsPressureSize": 1.0,
                                    "dynamicsPressureOpacity": 0.5, "shapeScatter": 0.5, "shapeRotation": 1.0,
                                    "shapeRandomise": true, "dynamicsJitterSize": 0.25, "dynamicsJitterOpacity": 0.1])
        let file = directory.appendingPathComponent("Fine.brush")
        try zip([("Shape.png", shape), ("Brush.archive", archive)]).write(to: file)

        let brush = try XCTUnwrap(library.importBrushes(from: file).first)
        XCTAssertEqual(brush.name, "Fine Pen")
        XCTAssertEqual(brush.baseSize, 10, "a fiftieth of the size slider")
        XCTAssertEqual(brush.pressureDynamics.sizeRange, 0...1)
        XCTAssertEqual(brush.pressureDynamics.opacityRange, 0.5...1)
        guard case .stamp(let settings) = brush.rendering else { return XCTFail("a stamp brush") }
        XCTAssertEqual(settings.spacing, 0.05, accuracy: 1e-4, "the square root of what is stored")
        XCTAssertEqual(settings.scatter, 0.5)
        XCTAssertTrue(settings.followsDirection)
        XCTAssertEqual(settings.angleJitter, 1)
        XCTAssertEqual(settings.sizeJitter, 0.25)
        XCTAssertEqual(settings.opacityJitter, 0.1, accuracy: 1e-6)
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

    // MARK: - Files from the wild

    /// Real brush files, when a directory of them is given: `ARTSY_REAL_BRUSHES=<dir>`
    /// (`TEST_RUNNER_ARTSY_REAL_BRUSHES` to xcodebuild). Every `.abr`, `.brush` and
    /// `.brushset` in it is parsed, imported into a scratch library, and each brush draws a
    /// stroke. What was found is printed as `REALBRUSH` lines; with `ARTSY_REAL_BRUSHES_OUT`
    /// set to a directory, each brush's stroke is written there as a PNG to look at.
    func testRealBrushFilesFromDisk() throws {
        let environment = ProcessInfo.processInfo.environment
        guard let path = environment["ARTSY_REAL_BRUSHES"] else {
            throw XCTSkip("set ARTSY_REAL_BRUSHES to a directory of .abr, .brush and .brushset files")
        }
        let out = environment["ARTSY_REAL_BRUSHES_OUT"].map { URL(fileURLWithPath: $0) }
        let files = try FileManager.default.contentsOfDirectory(at: URL(fileURLWithPath: path), includingPropertiesForKeys: nil)
            .filter { ["abr", "brush", "brushset"].contains($0.pathExtension.lowercased()) }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        XCTAssertFalse(files.isEmpty, "no brush files in \(path)")
        EngineHarness.sharedContext.brushTextures.userTextureDirectory = library.texturesDirectory

        for file in files {
            let data = try Data(contentsOf: file)
            let start = Date()
            if file.pathExtension.lowercased() == "abr" {
                let tips = try PhotoshopBrushFile.tips(in: data)
                let sizes = tips.prefix(8).map { "\($0.width)×\($0.height)" }.joined(separator: " ")
                print("REALBRUSH \(file.lastPathComponent): \(tips.count) tips [\(sizes)…], named: \(tips.compactMap(\.name).count)")
                XCTAssertFalse(tips.isEmpty, file.lastPathComponent)
            } else {
                let brushes = try ProcreateBrushFile.brushes(in: data, fileName: file.deletingPathExtension().lastPathComponent)
                print("REALBRUSH \(file.lastPathComponent): \(brushes.count) brushes, \(brushes.filter { $0.shape != nil }.count) with a shape, "
                      + "\(brushes.filter { $0.grain != nil }.count) with a grain: \(brushes.map(\.name).joined(separator: ", "))")
                XCTAssertFalse(brushes.isEmpty, file.lastPathComponent)
            }
            let imported = try library.importBrushes(from: file)
            print("REALBRUSH \(file.lastPathComponent): imported \(imported.count) in \(String(format: "%.2f", Date().timeIntervalSince(start))) s")
            XCTAssertFalse(imported.isEmpty, file.lastPathComponent)

            // Every brush draws: a line at full pressure on a small canvas
            for (index, brush) in imported.enumerated() {
                let harness = try EngineHarness(width: 160, height: 120)
                harness.select(brush)
                harness.viewModel.brushSize = 48
                harness.draw(StrokeFixtures.line(from: CGPoint(x: 40, y: 60), to: CGPoint(x: 120, y: 60), pressure: 1...1))
                let values = harness.pixels(of: harness.drawingLayer.texture).values
                var ink: Float = 0
                for i in stride(from: 3, to: values.count, by: 4) { ink += values[i] }
                XCTAssertGreaterThan(ink, 20, "\(file.lastPathComponent) / \(brush.name) draws nothing")
                if let out {
                    let name = brush.name.replacingOccurrences(of: "/", with: "-")
                    try Golden.write(harness.displayed(), to: out.appendingPathComponent(
                        "\(file.deletingPathExtension().lastPathComponent)-\(String(format: "%02d", index))-\(name).png"))
                }
            }
        }
    }
}

/// Encodes like Procreate's `SilicaBrush`: its settings as plain keyed values.
@objc(ArtsyTestsSilicaBrushStandIn)
private final class SilicaBrushStandIn: NSObject, NSCoding {
    let values: [String: Any]
    init(values: [String: Any]) { self.values = values }
    required init?(coder: NSCoder) { nil }
    func encode(with coder: NSCoder) {
        for (key, value) in values { coder.encode(value, forKey: key) }
    }
}
