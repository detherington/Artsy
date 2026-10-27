import Foundation
import AVFoundation
import CoreMedia

/// The time-lapse as a movie to watch or export: the document's segments in order on one
/// track, every frame a thirtieth of a second at full length, or cut to a length a long
/// recording is sped up to fit, the frames still in order and only the ones that land on
/// a thirtieth kept. Rendered at the recording's last frame size, with a segment recorded
/// at another size fitted in (`docs/timelapse-plan.md`).
public struct TimelapseMovie {
    public enum Length: Equatable {
        /// Every frame, a thirtieth of a second each.
        case full
        /// At most this long: a longer recording plays faster to fit.
        case seconds(TimeInterval)
        public static let thirtySeconds = Length.seconds(30)
    }

    public let composition: AVComposition
    public let videoComposition: AVVideoComposition
    /// How long the movie plays.
    public let duration: TimeInterval
    /// How long the recording is at full length, whatever the cut.
    public let recordedDuration: TimeInterval
    /// The frames in the recording.
    public let frames: Int
    /// The frame size the movie is rendered at: the recording's.
    public let size: CGSize
    /// Whether playing needs the video composition: a cut, or a segment of another size.
    /// A full-length replay of segments all at the frame size plays the composition as it
    /// is, which the simulator's player can do where it cannot run a video composition.
    public let needsVideoComposition: Bool

    public enum Failure: LocalizedError {
        case noRecording
        case exportFailed
        public var errorDescription: String? {
            switch self {
            case .noRecording: return "This canvas has no time-lapse yet"
            case .exportFailed: return "The time-lapse could not be exported"
            }
        }
    }

    /// The movie of the time-lapse in `folder`, a document's `timelapse` folder, at
    /// `length`. A segment that cannot be read is left out with a diagnostics line; one
    /// a crash left without its frame count plays as far as it was written.
    public static func load(from folder: URL, length: Length = .full) async throws -> TimelapseMovie {
        guard let manifest = TimelapseRecorder.manifest(in: folder) else { throw Failure.noRecording }
        let composition = AVMutableComposition()
        guard let track = composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid) else {
            throw Failure.noRecording
        }
        var sizes: [CGSize] = []
        var cursor = CMTime.zero
        for segment in manifest.segments {
            do {
                let asset = AVURLAsset(url: folder.appendingPathComponent(segment.file))
                guard let source = try await asset.loadTracks(withMediaType: .video).first else { continue }
                let (range, natural) = try await source.load(.timeRange, .naturalSize)
                try track.insertTimeRange(range, of: source, at: cursor)
                cursor = cursor + range.duration
                sizes.append(natural)
            } catch {
                DiagnosticsLog.shared.error(error, doing: "reading the time-lapse segment \(segment.file)")
            }
        }
        guard !sizes.isEmpty else { throw Failure.noRecording }

        let recorded = cursor.seconds
        var cut = false
        if case .seconds(let limit) = length, recorded > limit {
            composition.scaleTimeRange(CMTimeRange(start: .zero, duration: cursor),
                                       toDuration: CMTime(seconds: limit, preferredTimescale: 600))
            cut = true
        }
        let size = CGSize(width: manifest.width, height: manifest.height)
        let video = AVMutableVideoComposition()
        video.renderSize = size
        video.frameDuration = CMTime(value: 1, timescale: CMTimeScale(manifest.framesPerSecond))
        video.instructions = instructions(for: track, sizes: sizes, in: size, duration: composition.duration)
        return TimelapseMovie(composition: composition.copy() as! AVComposition,
                              videoComposition: video.copy() as! AVVideoComposition,
                              duration: composition.duration.seconds, recordedDuration: recorded,
                              frames: Int((recorded * Double(manifest.framesPerSecond)).rounded()), size: size,
                              needsVideoComposition: cut || !sizes.allSatisfy { $0 == size })
    }

    /// One instruction over the whole movie when every segment is the frame's size, else
    /// one a segment, scaling it to fit the frame, centred.
    private static func instructions(for track: AVMutableCompositionTrack, sizes: [CGSize], in frame: CGSize,
                                     duration: CMTime) -> [AVVideoCompositionInstructionProtocol] {
        if sizes.allSatisfy({ $0 == frame }) {
            let instruction = AVMutableVideoCompositionInstruction()
            instruction.timeRange = CMTimeRange(start: .zero, duration: duration)
            instruction.layerInstructions = [AVMutableVideoCompositionLayerInstruction(assetTrack: track)]
            return [instruction]
        }
        let segments = track.segments ?? []
        return segments.enumerated().map { index, segment in
            var range = segment.timeMapping.target
            if index == segments.count - 1 { range = CMTimeRange(start: range.start, end: max(range.end, duration)) }
            let size = sizes[min(index, sizes.count - 1)]
            let scale = min(frame.width / size.width, frame.height / size.height)
            let layer = AVMutableVideoCompositionLayerInstruction(assetTrack: track)
            layer.setTransform(CGAffineTransform(translationX: (frame.width - size.width * scale) / 2,
                                                 y: (frame.height - size.height * scale) / 2)
                                   .scaledBy(x: scale, y: scale), at: range.start)
            let instruction = AVMutableVideoCompositionInstruction()
            instruction.timeRange = range
            instruction.layerInstructions = [layer]
            return instruction
        }
    }

    /// The movie for an `AVPlayer`.
    public func playerItem() -> AVPlayerItem {
        let item = AVPlayerItem(asset: composition)
        if needsVideoComposition { item.videoComposition = videoComposition }
        return item
    }

    /// Writes the movie to `url` as an H.264 MP4 at the frame size, the kind every player
    /// and site takes, replacing a file there. `progress` is called now and then with
    /// 0…1, on no particular thread; cancelling the task stops the export.
    public func export(to url: URL, progress: ((Double) -> Void)? = nil) async throws {
        guard let session = AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetHighestQuality) else {
            throw Failure.exportFailed
        }
        session.videoComposition = videoComposition
        session.outputURL = url
        session.outputFileType = .mp4
        session.shouldOptimizeForNetworkUse = true
        try? FileManager.default.removeItem(at: url)
        let polling = Task {
            while !Task.isCancelled {
                progress?(Double(session.progress))
                try await Task.sleep(nanoseconds: 250_000_000)
            }
        }
        defer { polling.cancel() }
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                session.exportAsynchronously {
                    switch session.status {
                    case .completed: continuation.resume()
                    case .cancelled: continuation.resume(throwing: CancellationError())
                    default: continuation.resume(throwing: session.error ?? Failure.exportFailed)
                    }
                }
            }
        } onCancel: {
            session.cancelExport()
        }
        progress?(1)
    }
}
