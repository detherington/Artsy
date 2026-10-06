import XCTest
import Metal
@testable import Artsy

/// The diagnostics log a session on another Mac brings back.
final class DiagnosticsTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("ArtsyDiagnosticsTests-\(UUID().uuidString)")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    func testTheLogWritesWhatItIsToldAndWhatItRunsOn() throws {
        let log = DiagnosticsLog(directory: directory)
        log.launched(device: EngineHarness.sharedContext.device)
        log.note(.stroke, "Hard Round 12 px: 40 samples")
        log.error(DocumentError.saveFailed, doing: "saving Test.artsy")
        log.flush()

        let text = try String(contentsOf: XCTUnwrap(log.fileURL), encoding: .utf8)
        XCTAssertTrue(text.contains("app      Artsy "), text)
        XCTAssertTrue(text.contains("on macOS "), text)
        XCTAssertTrue(text.contains("GPU \(EngineHarness.sharedContext.device.name)"), text)
        XCTAssertTrue(text.contains("settings: smoothing"), text)
        XCTAssertTrue(text.contains("stroke   Hard Round 12 px: 40 samples"), text)
        XCTAssertTrue(text.contains("error    saving Test.artsy: Failed to save document"), text)
        XCTAssertEqual(text.components(separatedBy: "\n").filter { !$0.isEmpty }.count, 7, "one line each")
    }

    func testFrameTimingsAreSummarisedEveryFewSeconds() {
        let timings = DiagnosticsLog.FrameTimings(interval: 1)
        XCTAssertNil(timings.frame(encodeMilliseconds: 1, recomposited: true, at: 100))
        XCTAssertNil(timings.frame(encodeMilliseconds: 3, recomposited: false, at: 100.5))
        XCTAssertEqual(timings.frame(encodeMilliseconds: 2, recomposited: false, at: 101.2),
                       "3 frames in 1.2 s, 1 recomposited, encode p50 2.00 ms p95 3.00 ms max 3.00 ms")
        XCTAssertNil(timings.frame(encodeMilliseconds: 4, recomposited: true, at: 101.5), "a new interval begins")
        XCTAssertEqual(timings.frame(encodeMilliseconds: 5, recomposited: false, at: 102.3),
                       "2 frames in 1.1 s, 1 recomposited, encode p50 5.00 ms p95 5.00 ms max 5.00 ms")
    }

    func testTheBundleGathersTheFoldersAndASummary() throws {
        // A stand-in for ~/Library/Application Support/Artsy
        let support = directory.appendingPathComponent("Artsy")
        for name in ["Diagnostics", "Stroke Recordings", "Brushes"] {
            try FileManager.default.createDirectory(at: support.appendingPathComponent(name), withIntermediateDirectories: true)
        }
        try "stroke".write(to: support.appendingPathComponent("Stroke Recordings/one.json"), atomically: true, encoding: .utf8)
        let log = DiagnosticsLog(directory: support.appendingPathComponent("Diagnostics"))
        log.note(.app, "hello")

        let bundle = directory.appendingPathComponent("Artsy Diagnostics")
        try DiagnosticsLog.gatherBundle(to: bundle, from: support, log: log, device: EngineHarness.sharedContext.device)
        let names = try FileManager.default.contentsOfDirectory(atPath: bundle.path).sorted()
        XCTAssertEqual(names, ["Brushes", "Diagnostics", "Stroke Recordings", "summary.txt"])
        XCTAssertTrue(try String(contentsOf: bundle.appendingPathComponent("summary.txt"), encoding: .utf8).contains("GPU"))
        XCTAssertTrue(try String(contentsOf: bundle.appendingPathComponent("Diagnostics").appendingPathComponent(
            XCTUnwrap(log.fileURL).lastPathComponent), encoding: .utf8).contains("hello"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: bundle.appendingPathComponent("Stroke Recordings/one.json").path))
    }
}
