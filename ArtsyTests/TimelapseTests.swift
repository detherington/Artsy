import XCTest
import AVFoundation
@testable import Artsy
@testable import ArtsyEngine

/// The time-lapse: a frame for every settled change and none while the pen is down, the
/// segment a playable video of the frame's size, a save carrying the folder into the
/// package and the next opening writing a second segment, the switch off taking nothing.
final class TimelapseTests: XCTestCase {
    private var folder: URL!

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("TimelapseTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: folder)
    }

    /// A finished segment's frame count, size and length, read back from the file.
    private func video(_ url: URL) async throws -> (frames: Int, size: CGSize, seconds: Double) {
        let asset = AVURLAsset(url: url)
        let tracks = try await asset.loadTracks(withMediaType: .video)
        let track = try XCTUnwrap(tracks.first)
        let size = try await track.load(.naturalSize)
        let duration = try await asset.load(.duration).seconds
        let rate = try await track.load(.nominalFrameRate)
        return (Int((duration * Double(rate)).rounded()), size, duration)
    }

    private func waitForFinish(_ recorder: TimelapseRecorder) {
        let done = expectation(description: "segment finished")
        recorder.finishSegment { done.fulfill() }
        wait(for: [done], timeout: 10)
    }

    func testTheFrameIsTheCanvasHeldToTheLongestSideAndNeverGrown() {
        XCTAssertEqual(TimelapseRecorder.frameSize(for: CGSize(width: 2048, height: 1536), longestSide: 1920).width, 1920)
        XCTAssertEqual(TimelapseRecorder.frameSize(for: CGSize(width: 2048, height: 1536), longestSide: 1920).height, 1440)
        XCTAssertEqual(TimelapseRecorder.frameSize(for: CGSize(width: 800, height: 600), longestSide: 1920).width, 800, "never grown")
        XCTAssertEqual(TimelapseRecorder.frameSize(for: CGSize(width: 4000, height: 3000), longestSide: 3840).width, 3840)
        let odd = TimelapseRecorder.frameSize(for: CGSize(width: 1001, height: 333), longestSide: 1920)
        XCTAssertEqual(odd.width % 2, 0)
        XCTAssertEqual(odd.height % 2, 0)
    }

    func testAFrameForEverySettledChangeAndNoneMidStroke() async throws {
        let harness = try EngineHarness(width: 240, height: 160)
        harness.select(.pencil)
        let recorder = try TimelapseRecorder(directory: folder.appendingPathComponent("tl"), canvasSize: harness.viewModel.canvasSize,
                                             context: harness.context)
        harness.renderer.timelapse = recorder
        XCTAssertEqual(recorder.frameWidth, 240)
        XCTAssertEqual(recorder.frameHeight, 160)

        // Three strokes, each composited while the pen is down and once more after it lifts
        for y in [40, 80, 120] {
            harness.draw(StrokeFixtures.line(from: CGPoint(x: 20, y: CGFloat(y)), to: CGPoint(x: 220, y: CGFloat(y)), duration: 0.3))
            harness.renderFrameAsTheAppWould()
        }
        // A change that is not a stroke, and an undo of it
        harness.viewModel.noteContentChanged()
        harness.renderFrameAsTheAppWould()
        // Nothing changed: no frame
        harness.renderFrameAsTheAppWould()
        harness.renderFrameAsTheAppWould()
        // The GPU's completions land on the recorder's queue before the segment finishes
        waitForFinish(recorder)

        XCTAssertEqual(recorder.manifest.segments.count, 1)
        XCTAssertEqual(recorder.manifest.segments[0].frames, 4, "three strokes and a change")
        XCTAssertEqual(recorder.manifest.totalFrames, 4)
        let file = recorder.directory.appendingPathComponent(recorder.manifest.segments[0].file)
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path))
        let played = try await video(file)
        XCTAssertEqual(played.size, CGSize(width: 240, height: 160))
        XCTAssertEqual(played.seconds, 4.0 / 30, accuracy: 0.02)
        XCTAssertGreaterThan(recorder.bytes, 0)
        XCTAssertNotNil(TimelapseRecorder.manifest(in: recorder.directory), "the manifest is written")
    }

    func testTheSaveCarriesTheFolderAndTheNextOpeningWritesASecondSegment() async throws {
        let harness = try EngineHarness(width: 120, height: 80)
        harness.select(.pencil)
        let temporary = try TimelapseRecorder(directory: TimelapseRecorder.temporaryFolder(), canvasSize: harness.viewModel.canvasSize,
                                              context: harness.context, temporary: true)
        harness.renderer.timelapse = temporary
        harness.draw(StrokeFixtures.line(from: CGPoint(x: 10, y: 40), to: CGPoint(x: 110, y: 40), duration: 0.2))
        harness.renderFrameAsTheAppWould()
        let temporaryFolder = temporary.directory

        let document = folder.appendingPathComponent("Timed.artsy")
        let saved = expectation(description: "saved")
        CanvasDocument.saveAsync(renderer: harness.renderer, viewModel: harness.viewModel, to: document) { result in
            if case .failure(let error) = result { XCTFail("\(error)") }
            saved.fulfill()
        }
        await fulfillment(of: [saved], timeout: 20)
        let inDocument = TimelapseRecorder.folder(of: document)
        let manifest = try XCTUnwrap(TimelapseRecorder.manifest(in: inDocument))
        XCTAssertEqual(manifest.segments.map(\.frames), [1], "the segment finished for the save, with its one frame")
        XCTAssertTrue(FileManager.default.fileExists(atPath: inDocument.appendingPathComponent("0001.mov").path))
        XCTAssertEqual(temporary.directory, inDocument, "the recorder now writes in the document")

        // A second stroke after the save goes into a second segment, and the next save keeps both
        harness.draw(StrokeFixtures.line(from: CGPoint(x: 10, y: 20), to: CGPoint(x: 110, y: 20), duration: 0.2))
        harness.renderFrameAsTheAppWould()
        let savedAgain = expectation(description: "saved again")
        CanvasDocument.saveAsync(renderer: harness.renderer, viewModel: harness.viewModel, to: document) { _ in savedAgain.fulfill() }
        await fulfillment(of: [savedAgain], timeout: 20)
        let again = try XCTUnwrap(TimelapseRecorder.manifest(in: inDocument))
        XCTAssertEqual(again.segments.map(\.frames), [1, 1])
        XCTAssertEqual(again.totalFrames, 2)
        _ = temporaryFolder

        // Opened again, the document gets a recorder that knows both and writes a third
        let opened = try CanvasDocument.load(from: document, metalContext: harness.context)
        let recorder = try XCTUnwrap(opened.renderer.timelapse, "a document that has recorded goes on recording")
        XCTAssertEqual(recorder.manifest.segments.count, 2)
        opened.viewModel.noteContentChanged()
        let commandBuffer = harness.context.commandQueue.makeCommandBuffer()!
        opened.renderer.encodeFrame(into: commandBuffer)
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()
        waitForFinish(recorder)
        XCTAssertEqual(recorder.manifest.segments.map(\.frames), [1, 1, 1])
        let third = try await video(inDocument.appendingPathComponent("0003.mov"))
        XCTAssertEqual(third.size, CGSize(width: 120, height: 80))
    }

    func testRecordingOffTakesNothingAndStaysOffWhenOpenedAgain() async throws {
        let harness = try EngineHarness(width: 120, height: 80)
        harness.select(.pencil)
        let document = folder.appendingPathComponent("Quiet.artsy")
        let recorder = try TimelapseRecorder(directory: TimelapseRecorder.folder(of: document), canvasSize: harness.viewModel.canvasSize,
                                             context: harness.context)
        recorder.setRecording(false)
        harness.renderer.timelapse = recorder
        harness.draw(StrokeFixtures.line(from: CGPoint(x: 10, y: 40), to: CGPoint(x: 110, y: 40), duration: 0.2))
        harness.renderFrameAsTheAppWould()
        waitForFinish(recorder)
        XCTAssertEqual(recorder.manifest.totalFrames, 0)
        XCTAssertTrue(recorder.manifest.segments.isEmpty, "no segment begun")

        let saved = expectation(description: "saved")
        CanvasDocument.saveAsync(renderer: harness.renderer, viewModel: harness.viewModel, to: document) { _ in saved.fulfill() }
        await fulfillment(of: [saved], timeout: 20)
        let opened = try CanvasDocument.load(from: document, metalContext: harness.context)
        let again = try XCTUnwrap(opened.renderer.timelapse, "the document's own switch is kept, off")
        XCTAssertFalse(again.isRecording)
    }

    /// `count` settled changes, each a frame, a change tried again when the recorder had no
    /// room for it.
    private func take(_ count: Int, on harness: EngineHarness, _ recorder: TimelapseRecorder) async {
        let target = recorder.frames + count
        var tries = 0
        while recorder.frames < target, tries < count * 50 {
            tries += 1
            harness.viewModel.noteContentChanged()
            harness.renderFrameAsTheAppWould()
            await Task.yield()
        }
        XCTAssertEqual(recorder.frames, target, "every change a frame")
    }

    func testAOneFrameSegmentLastsAThirtieth() async throws {
        let harness = try EngineHarness(width: 96, height: 64)
        let recorder = try TimelapseRecorder(directory: folder.appendingPathComponent("one"), canvasSize: harness.viewModel.canvasSize,
                                             context: harness.context)
        harness.renderer.timelapse = recorder
        await take(1, on: harness, recorder)
        waitForFinish(recorder)
        XCTAssertEqual(recorder.manifest.segments.map(\.frames), [1])
        let played = try await video(recorder.directory.appendingPathComponent("0001.mov"))
        XCTAssertEqual(played.seconds, 1.0 / 30, accuracy: 0.002)
        XCTAssertEqual(played.frames, 1)
    }

    func testAFrameStillOnTheGPUWhenTheSegmentEndsIsKept() async throws {
        let harness = try EngineHarness(width: 96, height: 64)
        let recorder = try TimelapseRecorder(directory: folder.appendingPathComponent("gpu"), canvasSize: harness.viewModel.canvasSize,
                                             context: harness.context)
        harness.renderer.timelapse = recorder
        await take(1, on: harness, recorder)
        // The second frame is committed and the segment finished before the GPU has run it,
        // as a save or a close right after a stroke does
        harness.viewModel.noteContentChanged()
        let commandBuffer = harness.context.commandQueue.makeCommandBuffer()!
        harness.renderer.encodeFrame(into: commandBuffer)
        commandBuffer.commit()
        recorder.finishSegmentAndWait()
        XCTAssertEqual(recorder.manifest.segments.map(\.frames), [2])
        let played = try await video(recorder.directory.appendingPathComponent("0001.mov"))
        XCTAssertEqual(played.frames, 2, "the frame on the GPU is in the file")
        XCTAssertEqual(played.seconds, 2.0 / 30, accuracy: 0.002)
    }

    func testFullLengthPlaysEveryFrameAndACutPlaysFasterToFit() async throws {
        let harness = try EngineHarness(width: 96, height: 64)
        let tl = folder.appendingPathComponent("tl")
        let recorder = try TimelapseRecorder(directory: tl, canvasSize: harness.viewModel.canvasSize, context: harness.context)
        harness.renderer.timelapse = recorder
        await take(200, on: harness, recorder)
        waitForFinish(recorder)
        await take(100, on: harness, recorder)
        XCTAssertEqual(recorder.frames, 300)
        XCTAssertEqual(recorder.duration, 10, accuracy: 0.001)

        // Full length: 300 frames over two segments play 10 s, the segment in hand finished first
        let full = try await recorder.movie()
        XCTAssertEqual(recorder.manifest.segments.map(\.frames), [200, 100])
        XCTAssertEqual(full.duration, 10, accuracy: 0.001)
        XCTAssertEqual(full.recordedDuration, 10, accuracy: 0.001)
        XCTAssertEqual(full.frames, 300)
        XCTAssertEqual(full.size, CGSize(width: 96, height: 64))
        let fullFile = folder.appendingPathComponent("full.mp4")
        let progress = Progress()
        try await full.export(to: fullFile) { progress.values.append($0) }
        let exported = try await video(fullFile)
        XCTAssertEqual(exported.seconds, 10, accuracy: 0.05)
        XCTAssertEqual(exported.frames, 300)
        XCTAssertEqual(exported.size, CGSize(width: 96, height: 64))
        XCTAssertEqual(progress.values.last, 1)

        // Cut to 2 s: five times faster, 60 of the frames, still 30 a second
        let cut = try await TimelapseMovie.load(from: tl, length: .seconds(2))
        XCTAssertEqual(cut.duration, 2, accuracy: 0.001)
        XCTAssertEqual(cut.recordedDuration, 10, accuracy: 0.001)
        XCTAssertEqual(cut.frames, 300, "the recording's frames, whatever the cut")
        let cutFile = folder.appendingPathComponent("cut.mp4")
        try await cut.export(to: cutFile)
        let short = try await video(cutFile)
        XCTAssertEqual(short.seconds, 2, accuracy: 0.05)
        XCTAssertEqual(short.frames, 60)

        // A cut longer than the recording is the recording
        let loose = try await TimelapseMovie.load(from: tl, length: .thirtySeconds)
        XCTAssertEqual(loose.duration, 10, accuracy: 0.001)

        // The next change after a replay goes into a third segment
        await take(1, on: harness, recorder)
        waitForFinish(recorder)
        XCTAssertEqual(recorder.manifest.segments.map(\.frames), [200, 100, 1])
    }

    func testASegmentRecordedAtAnotherFrameSizeIsKeptAndFittedIntoTheLast() async throws {
        let harness = try EngineHarness(width: 192, height: 128)
        let tl = folder.appendingPathComponent("tl")
        // Recorded with the frame held to 96, then opened with the setting raised: the canvas's own 192
        let small = try TimelapseRecorder(directory: tl, canvasSize: harness.viewModel.canvasSize, context: harness.context,
                                          longestSide: 96)
        XCTAssertEqual(small.frameWidth, 96)
        harness.renderer.timelapse = small
        await take(3, on: harness, small)
        waitForFinish(small)
        let large = try TimelapseRecorder(directory: tl, canvasSize: harness.viewModel.canvasSize, context: harness.context)
        XCTAssertEqual(large.manifest.segments.map(\.frames), [3], "the segment recorded at the old size is kept")
        XCTAssertEqual(large.manifest.width, 192, "the frame is the new size")
        harness.renderer.timelapse = large
        await take(2, on: harness, large)
        let movie = try await large.movie()
        XCTAssertEqual(large.manifest.segments.map(\.frames), [3, 2])
        XCTAssertEqual(movie.size, CGSize(width: 192, height: 128))
        XCTAssertEqual(movie.frames, 5)
        let file = folder.appendingPathComponent("mixed.mp4")
        try await movie.export(to: file)
        let exported = try await video(file)
        XCTAssertEqual(exported.size, CGSize(width: 192, height: 128))
        XCTAssertEqual(exported.frames, 5)
    }

    func testAFolderWithNoRecordingHasNoMovie() async {
        do {
            _ = try await TimelapseMovie.load(from: folder.appendingPathComponent("none"))
            XCTFail("loaded")
        } catch TimelapseMovie.Failure.noRecording {
        } catch {
            XCTFail("\(error)")
        }
    }

    func testATemporaryRecorderCarriedIntoTheDocumentLeavesTheFolderWhenReleased() async throws {
        let harness = try EngineHarness(width: 96, height: 64)
        var temporary: TimelapseRecorder? = try TimelapseRecorder(directory: TimelapseRecorder.temporaryFolder(),
                                                                  canvasSize: harness.viewModel.canvasSize,
                                                                  context: harness.context, temporary: true)
        harness.renderer.timelapse = temporary
        await take(1, on: harness, temporary!)
        let document = folder.appendingPathComponent("Kept.artsy")
        let saved = expectation(description: "saved")
        CanvasDocument.saveAsync(renderer: harness.renderer, viewModel: harness.viewModel, to: document) { _ in saved.fulfill() }
        await fulfillment(of: [saved], timeout: 20)
        let segment = TimelapseRecorder.folder(of: document).appendingPathComponent("0001.mov")
        XCTAssertTrue(FileManager.default.fileExists(atPath: segment.path))
        // The canvas closes: the recorder goes, and the document's folder stays
        harness.renderer.timelapse = nil
        temporary = nil
        XCTAssertTrue(FileManager.default.fileExists(atPath: segment.path), "the document's folder is not the temporary one")
    }

    func testDeleteTakesTheSegmentsAndKeepsTheSwitch() async throws {
        let harness = try EngineHarness(width: 96, height: 64)
        let tl = folder.appendingPathComponent("tl")
        let recorder = try TimelapseRecorder(directory: tl, canvasSize: harness.viewModel.canvasSize, context: harness.context)
        harness.renderer.timelapse = recorder
        await take(30, on: harness, recorder)
        XCTAssertTrue(recorder.summary.hasPrefix("1 s, "), recorder.summary)
        await take(1, on: harness, recorder)
        XCTAssertTrue(recorder.summary.hasPrefix("1 s, "), "31 frames round to a second")
        recorder.deleteRecording()
        XCTAssertEqual(recorder.frames, 0)
        XCTAssertEqual(recorder.summary, "Nothing recorded yet")
        XCTAssertTrue(recorder.isRecording)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: tl.path), [TimelapseRecorder.manifestName])
        // Recording goes on, into a first segment again
        await take(2, on: harness, recorder)
        waitForFinish(recorder)
        XCTAssertEqual(recorder.manifest.segments.map(\.file), ["0001.mov"])
        XCTAssertEqual(recorder.manifest.segments.map(\.frames), [2])
    }

    func testTheSwitchTurnedOnWithNoRecorderStartsOne() throws {
        let harness = try EngineHarness(width: 96, height: 64)
        XCTAssertNil(harness.renderer.timelapse)
        let document = folder.appendingPathComponent("Switched.artsy")
        CanvasDocument.setTimelapseRecording(false, renderer: harness.renderer, documentURL: document)
        XCTAssertNil(harness.renderer.timelapse, "off with none makes none")
        CanvasDocument.setTimelapseRecording(true, renderer: harness.renderer, documentURL: document)
        let recorder = try XCTUnwrap(harness.renderer.timelapse)
        XCTAssertTrue(recorder.isRecording)
        XCTAssertEqual(recorder.directory, TimelapseRecorder.folder(of: document))
        CanvasDocument.setTimelapseRecording(false, renderer: harness.renderer, documentURL: document)
        XCTAssertFalse(recorder.isRecording)
        XCTAssertTrue(harness.renderer.timelapse === recorder, "the recorder stays, off")
    }

    func testASegmentACrashLeftWithoutItsCountStillPlays() async throws {
        let harness = try EngineHarness(width: 96, height: 64)
        let tl = folder.appendingPathComponent("tl")
        let recorder = try TimelapseRecorder(directory: tl, canvasSize: harness.viewModel.canvasSize, context: harness.context)
        harness.renderer.timelapse = recorder
        await take(5, on: harness, recorder)
        XCTAssertTrue(recorder.summary.hasPrefix("5 frames, "), "under a second, the frames are shown")
        waitForFinish(recorder)
        // The manifest as a crash leaves it: the segment begun, its count never written
        var manifest = try XCTUnwrap(TimelapseRecorder.manifest(in: tl))
        manifest.segments[0].frames = 0
        try JSONEncoder().encode(manifest).write(to: tl.appendingPathComponent(TimelapseRecorder.manifestName))
        let movie = try await TimelapseMovie.load(from: tl)
        XCTAssertEqual(movie.frames, 5, "the file knows its frames")
    }

    func testALengthIsDescribedAsAMenuShowsIt() {
        XCTAssertEqual(TimelapseRecorder.describe(duration: 12.4), "12 s")
        XCTAssertEqual(TimelapseRecorder.describe(duration: 200), "3 min 20 s")
        XCTAssertEqual(TimelapseRecorder.describe(duration: 120), "2 min")
        XCTAssertEqual(TimelapseRecorder.describe(duration: 3720), "1 h 2 min")
    }

    private final class Progress: @unchecked Sendable {
        var values: [Double] = []
    }
}
