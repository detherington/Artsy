import Foundation
import AVFoundation
import Combine
import CoreVideo
import Metal

/// The time-lapse of a canvas: a frame of video for every settled change, kept in the
/// document's `timelapse` folder as segments and a manifest (`docs/timelapse-plan.md`).
///
/// The renderer calls `capture` once a change has been composited with no stroke in
/// progress; the frame is a draw of the composite into a pixel buffer, encoded on the
/// frame's own command buffer, and appended to the segment's writer once the GPU has
/// run it, a thirtieth of a second after the last. Nothing is read back and nothing
/// waits. An `AVAssetWriter` cannot reopen a file, so every opening of the document
/// writes a new segment, finished before a save, on close, and when recording is turned
/// off; the manifest keeps the segments and their frame counts.
public final class TimelapseRecorder: ObservableObject {
    public struct Manifest: Codable, Equatable {
        public struct Segment: Codable, Equatable {
            public var file: String
            public var frames: Int
        }
        public var version = 1
        public var width: Int
        public var height: Int
        public var framesPerSecond = TimelapseRecorder.framesPerSecond
        /// Whether changes are being recorded; a document's own setting.
        public var recording = true
        public var segments: [Segment] = []

        public var totalFrames: Int { segments.reduce(0) { $0 + $1.frames } }
        public var duration: TimeInterval { Double(totalFrames) / Double(framesPerSecond) }
    }

    public static let folderName = "timelapse"
    public static let manifestName = "timelapse.json"
    public static let framesPerSecond = 30
    /// The longest side of a frame unless told otherwise: 1080p's.
    public static let defaultLongestSide = 1920
    /// Changes that are not a stroke, a fill or the like, but the composite moving on its
    /// own (water flowing), are taken no more often than this.
    static let quietInterval: TimeInterval = 0.25

    /// The folder the segments and manifest are in: the document's, or a temporary one
    /// until an unsaved canvas is first saved.
    public private(set) var directory: URL
    @Published public private(set) var manifest: Manifest
    public let frameWidth: Int
    public let frameHeight: Int
    private let context: MetalContext
    private var temporary: Bool
    private var textureCache: CVMetalTextureCache?
    private var pool: CVPixelBufferPool?
    private var writer: AVAssetWriter?
    private var input: AVAssetWriterInput?
    private var adaptor: AVAssetWriterInputPixelBufferAdaptor?
    private var segmentFile: String?
    @Published private var segmentFrames = 0
    /// Frames drawn on the GPU and not yet appended.
    private var inFlight = 0
    private let inFlightLock = NSLock()
    private var lastCapture: TimeInterval = 0
    private var lastCapturedVersion = -1
    private let queue = DispatchQueue(label: "com.artsy.timelapse")

    /// The recorder for the canvas of `canvasSize` whose time-lapse lives in `directory`,
    /// read from the manifest there if there is one; a frame is the canvas held to
    /// `longestSide`, never grown.
    public init(directory: URL, canvasSize: CGSize, context: MetalContext, longestSide: Int = defaultLongestSide,
                temporary: Bool = false) throws {
        self.directory = directory
        self.context = context
        self.temporary = temporary
        let size = Self.frameSize(for: canvasSize, longestSide: longestSide)
        let manifestURL = directory.appendingPathComponent(Self.manifestName)
        if let data = try? Data(contentsOf: manifestURL), var saved = try? JSONDecoder().decode(Manifest.self, from: data) {
            // The frame size can change with the setting between openings; the segments
            // recorded at the old size are kept and the movie fits them into the new frame
            saved.width = size.width
            saved.height = size.height
            manifest = saved
        } else {
            manifest = Manifest(width: size.width, height: size.height)
        }
        frameWidth = size.width
        frameHeight = size.height
        CVMetalTextureCacheCreate(kCFAllocatorDefault, nil, context.device, nil, &textureCache)
        let attributes: [CFString: Any] = [
            kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey: frameWidth,
            kCVPixelBufferHeightKey: frameHeight,
            kCVPixelBufferMetalCompatibilityKey: true,
            kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary,
        ]
        CVPixelBufferPoolCreate(kCFAllocatorDefault, [kCVPixelBufferPoolMinimumBufferCountKey: 3] as CFDictionary,
                                attributes as CFDictionary, &pool)
    }

    deinit {
        if temporary { try? FileManager.default.removeItem(at: directory) }
    }

    /// The frame for a canvas: its size held to `longestSide`, never grown, each side even
    /// as the encoder wants, and no smaller than 16.
    public static func frameSize(for canvasSize: CGSize, longestSide: Int) -> (width: Int, height: Int) {
        let longest = max(canvasSize.width, canvasSize.height, 1)
        let scale = min(1, CGFloat(longestSide) / longest)
        func even(_ value: CGFloat) -> Int { max(16, Int((value * scale).rounded()) / 2 * 2) }
        return (even(canvasSize.width), even(canvasSize.height))
    }

    // MARK: - Recording

    public var isRecording: Bool { manifest.recording }

    /// The frames recorded so far, the segment in hand included.
    public var frames: Int { manifest.totalFrames + segmentFrames }
    /// How long the time-lapse plays at full length, so far.
    public var duration: TimeInterval { Double(frames) / Double(Self.framesPerSecond) }

    /// The recording so far as a movie to watch or export: the segment in hand is finished
    /// first, so every frame is on disk; the next change starts a new one.
    public func movie(length: TimelapseMovie.Length = .full) async throws -> TimelapseMovie {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            finishSegment { continuation.resume() }
        }
        return try await TimelapseMovie.load(from: directory, length: length)
    }

    /// Turns recording on or off for this document; off finishes the segment in hand.
    public func setRecording(_ on: Bool) {
        guard manifest.recording != on else { return }
        manifest.recording = on
        if !on { finishSegment() }
        saveManifest()
    }

    /// A frame of `composite` over `background`, if recording and the moment is right:
    /// `contentVersion` is the view model's, so a stroke committed, a fill, a layer change
    /// or an undo is always taken, and the composite moving on its own (water) no more
    /// often than `quietInterval`. Encoded on `commandBuffer`; appended once it has run.
    public func capture(composite: MTLTexture, contentVersion: Int, background: (r: Double, g: Double, b: Double),
                        compositor: CompositorPipeline, commandBuffer: MTLCommandBuffer, now: TimeInterval) {
        guard manifest.recording else { return }
        let changed = contentVersion != lastCapturedVersion
        guard changed || now - lastCapture >= Self.quietInterval else { return }
        guard inFlightLock.withLock({ inFlight < 3 }), let pool, let textureCache else { return }
        if writer == nil { beginSegment() }
        guard let input, let adaptor, input.isReadyForMoreMediaData else { return }

        var pixelBuffer: CVPixelBuffer?
        guard CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &pixelBuffer) == kCVReturnSuccess,
              let pixelBuffer else { return }
        var metalTexture: CVMetalTexture?
        guard CVMetalTextureCacheCreateTextureFromImage(kCFAllocatorDefault, textureCache, pixelBuffer, nil, .bgra8Unorm,
                                                        frameWidth, frameHeight, 0, &metalTexture) == kCVReturnSuccess,
              let metalTexture, let texture = CVMetalTextureGetTexture(metalTexture) else { return }

        // The canvas fills the frame: its middle at the frame's, at the frame's scale
        var transform = CanvasTransform()
        transform.scale = CGFloat(frameWidth) / CGFloat(composite.width)
        transform.offset = CGPoint(x: -CGFloat(composite.width) / 2 * transform.scale,
                                   y: -CGFloat(composite.height) / 2 * transform.scale)
        compositor.renderToScreen(composite: composite, drawable: texture, transform: transform,
                                  viewSize: CGSize(width: frameWidth, height: frameHeight),
                                  backgroundColor: background, commandBuffer: commandBuffer)

        lastCapturedVersion = contentVersion
        lastCapture = now
        inFlightLock.withLock { inFlight += 1 }
        let time = CMTime(value: CMTimeValue(segmentFrames), timescale: CMTimeScale(Self.framesPerSecond))
        segmentFrames += 1
        let keep = metalTexture
        // Appended as soon as the GPU has run it, in order, the finish of the segment waiting for it
        commandBuffer.addCompletedHandler { [weak self] _ in
            withExtendedLifetime(keep) {}
            guard let self else { return }
            self.inFlightLock.withLock {
                if !input.isReadyForMoreMediaData {
                    DiagnosticsLog.shared.note(.error, "time-lapse frame dropped: the writer was busy")
                } else if !adaptor.append(pixelBuffer, withPresentationTime: time) {
                    DiagnosticsLog.shared.note(.error, "time-lapse frame dropped: \(self.writer?.error?.localizedDescription ?? "not appended")")
                }
                self.inFlight -= 1
            }
        }
    }

    /// Waits, up to `timeout`, for frames the GPU has not run yet; the last stroke before
    /// a save or a close is one.
    private func waitForFramesInFlight(timeout: TimeInterval = 1) {
        let deadline = Date().addingTimeInterval(timeout)
        while inFlightLock.withLock({ inFlight }) > 0, Date() < deadline { usleep(2000) }
    }

    private func beginSegment() {
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let file = String(format: "%04d.mov", manifest.segments.count + 1)
            let url = directory.appendingPathComponent(file)
            try? FileManager.default.removeItem(at: url)
            let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
            // Written in fragments, so a segment cut short by a crash still plays
            writer.movieFragmentInterval = CMTime(seconds: 2, preferredTimescale: 600)
            let settings = Self.videoSettings(width: frameWidth, height: frameHeight, writer: writer)
            let input = AVAssetWriterInput(mediaType: .video, outputSettings: settings)
            input.expectsMediaDataInRealTime = false
            let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: frameWidth,
                kCVPixelBufferHeightKey as String: frameHeight,
            ])
            guard writer.canAdd(input) else { throw Failure.cannotWrite }
            writer.add(input)
            guard writer.startWriting() else { throw writer.error ?? Failure.cannotWrite }
            writer.startSession(atSourceTime: .zero)
            self.writer = writer
            self.input = input
            self.adaptor = adaptor
            segmentFile = file
            segmentFrames = 0
            manifest.segments.append(Manifest.Segment(file: file, frames: 0))
            saveManifest()
        } catch {
            DiagnosticsLog.shared.error(error, doing: "starting a time-lapse segment")
            writer = nil
            input = nil
            adaptor = nil
        }
    }

    /// HEVC where the writer takes it, H.264 otherwise, at a rate that keeps a 1080p frame
    /// sharp without the file running away.
    private static func videoSettings(width: Int, height: Int, writer: AVAssetWriter) -> [String: Any] {
        let bitRate = max(2_000_000, width * height * 4)
        let hevc: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.hevc,
            AVVideoWidthKey: width, AVVideoHeightKey: height,
            AVVideoCompressionPropertiesKey: [AVVideoAverageBitRateKey: bitRate],
        ]
        if writer.canApply(outputSettings: hevc, forMediaType: .video) { return hevc }
        return [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: width, AVVideoHeightKey: height,
            AVVideoCompressionPropertiesKey: [AVVideoAverageBitRateKey: bitRate],
        ]
    }

    /// Finishes the segment in hand, if any, and writes the manifest with its frame count;
    /// `completion` once the file is whole. The next capture starts a new segment.
    public func finishSegment(completion: (() -> Void)? = nil) {
        guard let writer, let input, let file = segmentFile else {
            completion?()
            return
        }
        let frames = segmentFrames
        self.writer = nil
        self.input = nil
        self.adaptor = nil
        segmentFile = nil
        segmentFrames = 0
        queue.async { [weak self] in
            self?.waitForFramesInFlight()
            if frames == 0 {
                // Nothing was taken: no file to keep
                writer.cancelWriting()
                DispatchQueue.main.async {
                    self?.drop(segment: file)
                    completion?()
                }
                return
            }
            // The last frame lasts a thirtieth of a second like the rest
            writer.endSession(atSourceTime: CMTime(value: CMTimeValue(frames), timescale: CMTimeScale(Self.framesPerSecond)))
            input.markAsFinished()
            writer.finishWriting {
                DispatchQueue.main.async {
                    guard let self else { completion?(); return }
                    if writer.status == .failed, let error = writer.error {
                        DiagnosticsLog.shared.error(error, doing: "finishing a time-lapse segment")
                        self.drop(segment: file)
                    } else if let index = self.manifest.segments.firstIndex(where: { $0.file == file }) {
                        self.manifest.segments[index].frames = frames
                        self.saveManifest()
                    }
                    completion?()
                }
            }
        }
    }

    /// Takes a segment that has nothing to keep out of the manifest and off the disk.
    private func drop(segment file: String) {
        manifest.segments.removeAll { $0.file == file }
        try? FileManager.default.removeItem(at: directory.appendingPathComponent(file))
        saveManifest()
    }

    /// Finishes the segment and waits for it, up to `timeout`, for a save that is about to
    /// copy the folder.
    public func finishSegmentAndWait(timeout: TimeInterval = 5) {
        guard writer != nil else { return }
        let done = DispatchSemaphore(value: 0)
        finishSegment { done.signal() }
        // The completion comes on the main queue: spin it if this is the main thread
        if Thread.isMainThread {
            let deadline = Date().addingTimeInterval(timeout)
            while done.wait(timeout: .now()) == .timedOut, Date() < deadline {
                RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.01))
            }
        } else {
            _ = done.wait(timeout: .now() + timeout)
        }
    }

    /// The time-lapse now lives at `directory`: the document's folder after a save, or a
    /// renamed document's. The next segment is written there.
    public func moved(to directory: URL) {
        finishSegment()
        self.directory = directory
        // The document's folder now, not one to remove when the canvas closes
        temporary = false
    }

    /// Takes the recording away: the segments go, the switch stays. Recording goes on
    /// into a first segment again if it is on.
    public func deleteRecording() {
        finishSegmentAndWait()
        for segment in manifest.segments {
            try? FileManager.default.removeItem(at: directory.appendingPathComponent(segment.file))
        }
        manifest.segments = []
        lastCapturedVersion = -1
        saveManifest()
    }

    /// The recording's length and size as a menu shows it: "3 min 20 s, 212 MB", the
    /// frames instead while there is less than a second of them, or that there is nothing
    /// yet.
    public var summary: String {
        guard frames > 0 else { return "Nothing recorded yet" }
        let length = duration < 1 ? (frames == 1 ? "1 frame" : "\(frames) frames") : Self.describe(duration: duration)
        return length + ", " + ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
    }

    /// A length as a menu shows it: "12 s", "3 min 20 s", "2 min", "1 h 2 min".
    public static func describe(duration: TimeInterval) -> String {
        let seconds = Int(duration.rounded())
        if seconds < 60 { return "\(seconds) s" }
        if seconds < 3600 {
            return seconds % 60 == 0 ? "\(seconds / 60) min" : "\(seconds / 60) min \(seconds % 60) s"
        }
        let minutes = seconds % 3600 / 60
        return minutes == 0 ? "\(seconds / 3600) h" : "\(seconds / 3600) h \(minutes) min"
    }

    /// The size on disk of the segments, in bytes.
    public var bytes: Int {
        manifest.segments.reduce(0) { total, segment in
            let path = directory.appendingPathComponent(segment.file).path
            return total + ((try? FileManager.default.attributesOfItem(atPath: path)[.size] as? Int) ?? 0)
        }
    }

    private func saveManifest() {
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try JSONEncoder().encode(manifest).write(to: directory.appendingPathComponent(Self.manifestName), options: .atomic)
        } catch {
            DiagnosticsLog.shared.error(error, doing: "writing the time-lapse manifest")
        }
    }

    public enum Failure: LocalizedError {
        case cannotWrite
        public var errorDescription: String? { "The time-lapse could not be written" }
    }

    // MARK: - The document's folder

    /// The time-lapse folder of the document at `url`.
    public static func folder(of documentURL: URL) -> URL {
        documentURL.appendingPathComponent(folderName, isDirectory: true)
    }

    /// The manifest in `folder`, if there is one.
    public static func manifest(in folder: URL) -> Manifest? {
        guard let data = try? Data(contentsOf: folder.appendingPathComponent(manifestName)) else { return nil }
        return try? JSONDecoder().decode(Manifest.self, from: data)
    }

    /// A temporary folder for an unsaved canvas's time-lapse, moved into the document at
    /// its first save.
    public static func temporaryFolder() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("Artsy Time-lapse", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
    }

    /// The folder's files into `destination`, by hard link where the volumes allow and by
    /// copy otherwise, for a save that writes a fresh package.
    public static func stage(_ folder: URL, into destination: URL) throws {
        let fm = FileManager.default
        guard fm.fileExists(atPath: folder.path) else { return }
        try fm.createDirectory(at: destination, withIntermediateDirectories: true)
        for name in try fm.contentsOfDirectory(atPath: folder.path) {
            let from = folder.appendingPathComponent(name), to = destination.appendingPathComponent(name)
            do {
                try fm.linkItem(at: from, to: to)
            } catch {
                try fm.copyItem(at: from, to: to)
            }
        }
    }
}
