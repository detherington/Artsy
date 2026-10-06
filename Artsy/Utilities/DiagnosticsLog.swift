import Foundation
import AppKit
import Metal
import os.log

/// A plain-text record of what the app did, to bring back from a session on another Mac:
/// what it ran on, every pen that came near, each stroke's input rate and ranges, undo
/// steps, frame and commit timings, documents opened and saved, errors shown. One file per
/// launch in `~/Library/Application Support/Artsy/Diagnostics/`; the lines also go to the
/// unified log under `com.artsy.app`. Help ▸ Diagnostics gathers the folder, the stroke
/// recordings and the brush library into one bundle to send.
final class DiagnosticsLog {
    /// Replaced in tests with one that writes somewhere temporary.
    static var shared = DiagnosticsLog(directory: DiagnosticsLog.folder)

    enum Category: String {
        case app, pen, stroke, undo, frame, document, brush, tool, error
    }

    /// `~/Library/Application Support/Artsy/Diagnostics`.
    static var folder: URL? {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent("Artsy/Diagnostics", isDirectory: true)
    }

    let fileURL: URL?
    private let queue = DispatchQueue(label: "com.artsy.diagnostics", qos: .utility)
    private var handle: FileHandle?
    private let system = OSLog(subsystem: "com.artsy.app", category: "diagnostics")
    private let clock: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    /// Logs into a fresh, timestamped file in `directory`; nowhere if that cannot be made.
    init(directory: URL?) {
        var url: URL?
        if let directory {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.dateFormat = "yyyy-MM-dd HH.mm.ss"
            let candidate = directory.appendingPathComponent("artsy-\(formatter.string(from: Date())).log")
            do {
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                if FileManager.default.createFile(atPath: candidate.path, contents: nil) {
                    handle = try FileHandle(forWritingTo: candidate)
                    url = candidate
                }
            } catch {
                fputs("Artsy: no diagnostics log: \(error.localizedDescription)\n", stderr)
            }
        }
        fileURL = url
    }

    /// One line: the time, the category, the message.
    func note(_ category: Category, _ message: String) {
        let line = "\(clock.string(from: Date())) \(category.rawValue.padding(toLength: 8, withPad: " ", startingAt: 0)) \(message)\n"
        os_log("%{public}@ %{public}@", log: system, type: .info, category.rawValue, message)
        queue.async { [handle] in
            handle?.write(Data(line.utf8))
        }
    }

    /// An error the user was shown, and what was being done.
    func error(_ error: Error, doing what: String) {
        note(.error, "\(what): \(error.localizedDescription) (\(error))")
    }

    /// Everything written so far is on disk.
    func flush() {
        queue.sync { [handle] in try? handle?.synchronize() }
    }

    // MARK: - What it ran on

    /// The facts a session's findings are read against: the app, the Mac, the GPU and its
    /// memory, the screens, the settings that shape a stroke.
    func launched(device: MTLDevice?) {
        for line in Self.systemSummary(device: device) { note(.app, line) }
    }

    static func systemSummary(device: MTLDevice?) -> [String] {
        let bundle = Bundle.main
        let version = bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
        let build = bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?"
        let process = ProcessInfo.processInfo
        var lines = ["Artsy \(version) (\(build)) on macOS \(process.operatingSystemVersionString), \(hardwareModel)"]
        lines.append("memory \(process.physicalMemory / 1_048_576) MB, \(process.processorCount) cores")
        if let device {
            lines.append("GPU \(device.name), working set \(device.recommendedMaxWorkingSetSize / 1_048_576) MB, "
                         + "unified memory \(device.hasUnifiedMemory)")
        }
        let screens = NSScreen.screens.map { "\(Int($0.frame.width))×\(Int($0.frame.height)) @\($0.backingScaleFactor)x" }
        lines.append("screens " + (screens.isEmpty ? "none" : screens.joined(separator: ", ")))
        let prefs = AppPreferences.shared
        lines.append("settings: smoothing \(prefs.smoothingMode.rawValue), relief \(prefs.paintRelief), "
                     + "snap shapes \(prefs.snapShapesOnHold), ease without pressure \(prefs.easeStrokesWithoutPressure), "
                     + "record strokes \(StrokeRecorder.isEnabledInDefaults)")
        return lines
    }

    /// The Mac's model identifier, as `hw.model` says.
    static var hardwareModel: String {
        var size = 0
        sysctlbyname("hw.model", nil, &size, nil, 0)
        var model = [CChar](repeating: 0, count: max(size, 1))
        sysctlbyname("hw.model", &model, &size, nil, 0)
        return String(cString: model)
    }

    // MARK: - Frame timings

    /// Encode times of the frames since the last line, written out every few seconds.
    final class FrameTimings {
        private var encodeMilliseconds: [Double] = []
        private var recomposited = 0
        /// When the frames being summarised began: the first frame's time.
        private var since: TimeInterval?
        /// The slowest frame so far: how far into the window, and whether a stroke was on.
        private var slowest: (ms: Double, at: TimeInterval, drawing: Bool)?
        let interval: TimeInterval

        init(interval: TimeInterval = 5) { self.interval = interval }

        /// Returns the line to log, once `interval` has passed.
        func frame(encodeMilliseconds ms: Double, recomposited didRecomposite: Bool, drawing: Bool, at now: TimeInterval) -> String? {
            encodeMilliseconds.append(ms)
            if didRecomposite { recomposited += 1 }
            let since = self.since ?? now
            self.since = since
            if slowest.map({ ms > $0.ms }) ?? true { slowest = (ms, now - since, drawing) }
            guard now - since >= interval else { return nil }
            defer { self.since = now }
            let sorted = encodeMilliseconds.sorted()
            var line = String(format: "%d frames in %.1f s, %d recomposited, encode p50 %.2f ms p95 %.2f ms max %.2f ms",
                              sorted.count, now - since, recomposited,
                              sorted[sorted.count / 2], sorted[min(sorted.count - 1, sorted.count * 95 / 100)], sorted[sorted.count - 1])
            if let slowest, slowest.ms >= 8 {
                line += String(format: " (at +%.1f s, %@)", slowest.at, slowest.drawing ? "while drawing" : "idle")
            }
            encodeMilliseconds.removeAll(keepingCapacity: true)
            recomposited = 0
            slowest = nil
            return line
        }
    }

    // MARK: - The bundle to send

    /// Copy the diagnostics logs, the stroke recordings and the brush library into
    /// `destination` (a folder made here), with a summary of what this Mac is.
    static func gatherBundle(
        to destination: URL,
        from support: URL? = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent("Artsy"),
        log: DiagnosticsLog = shared,
        device: MTLDevice?
    ) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: destination, withIntermediateDirectories: true)
        log.flush()
        for name in ["Diagnostics", "Stroke Recordings", "Brushes"] {
            guard let source = support?.appendingPathComponent(name), fm.fileExists(atPath: source.path) else { continue }
            try fm.copyItem(at: source, to: destination.appendingPathComponent(name))
        }
        let summary = systemSummary(device: device).joined(separator: "\n") + "\n"
        try summary.write(to: destination.appendingPathComponent("summary.txt"), atomically: true, encoding: .utf8)
    }
}
