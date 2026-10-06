import Foundation

/// A session of raw pen input, saved so real strokes can be replayed without a view
/// (golden-image tests, benchmarks). Points are canvas-space and captured before
/// smoothing, so a replay goes through the same pipeline the live stroke did.
struct StrokeRecording: Codable, Equatable {
    static let currentVersion = 1

    var version = StrokeRecording.currentVersion
    var canvasWidth: Int
    var canvasHeight: Int
    var strokes: [RecordedStroke] = []
}

/// One stroke plus every setting that affects how it renders.
struct RecordedStroke: Codable, Equatable {
    var brushName: String
    var color: StrokeColor
    var size: Float
    var opacity: Float
    var pressureCurve: PressureCurve
    var smoothingMode: SmoothingMode
    var smoothingStrength: Float
    /// "off", "horizontal", "vertical", "quad" or "radial:N"
    var symmetry: String
    /// False for a mouse or trackpad. Absent in older recordings, which were all treated as pens.
    var hasPressure: Bool?
    var points: [RecordedPoint]

    /// Snapshot the view model's current drawing settings; points are added as they arrive.
    init(settingsFrom viewModel: CanvasViewModel, points: [RecordedPoint] = []) {
        self.brushName = viewModel.currentBrush.name
        self.color = viewModel.currentColor
        self.size = viewModel.brushSize
        self.opacity = viewModel.brushOpacity
        self.pressureCurve = viewModel.pressureCurve
        self.smoothingMode = viewModel.smoothingMode
        self.smoothingStrength = viewModel.smoothingStrength
        self.symmetry = viewModel.symmetryMode.recordingKey
        self.hasPressure = viewModel.strokeHasPressure
        self.points = points
    }

    /// Put the view model into the state this stroke was drawn with.
    /// Returns false if the brush no longer exists.
    @discardableResult
    func applySettings(to viewModel: CanvasViewModel) -> Bool {
        guard let brush = BrushLibrary.shared.brush(named: brushName) else { return false }
        viewModel.currentBrush = brush
        viewModel.currentColor = color
        viewModel.brushSize = size
        viewModel.brushOpacity = opacity
        viewModel.pressureCurve = pressureCurve
        viewModel.smoothingMode = smoothingMode
        viewModel.smoothingStrength = smoothingStrength
        viewModel.symmetryMode = SymmetryMode(recordingKey: symmetry)
        return true
    }
}

/// One input sample. Encoded as a bare array `[x, y, pressure, tiltX, tiltY, rotation, time]`
/// to keep recordings compact; `time` is seconds since the stroke began.
struct RecordedPoint: Codable, Equatable {
    var x: Double
    var y: Double
    var pressure: Double
    var tiltX: Double
    var tiltY: Double
    var rotation: Double
    var time: Double

    init(x: Double, y: Double, pressure: Double, tiltX: Double = 0, tiltY: Double = 0,
         rotation: Double = 0, time: Double) {
        self.x = x
        self.y = y
        self.pressure = pressure
        self.tiltX = tiltX
        self.tiltY = tiltY
        self.rotation = rotation
        self.time = time
    }

    init(_ point: StrokePoint, strokeStart: TimeInterval) {
        // Rounded so files stay small and a replay sees exactly what was saved.
        func rounded(_ value: Double, _ places: Double) -> Double { (value * places).rounded() / places }
        self.x = rounded(Double(point.position.x), 1_000)
        self.y = rounded(Double(point.position.y), 1_000)
        self.pressure = rounded(Double(point.pressure), 10_000)
        self.tiltX = rounded(Double(point.tiltX), 10_000)
        self.tiltY = rounded(Double(point.tiltY), 10_000)
        self.rotation = rounded(Double(point.rotation), 100)
        self.time = rounded(point.timestamp - strokeStart, 100_000)
    }

    var strokePoint: StrokePoint {
        StrokePoint(
            position: CGPoint(x: x, y: y),
            pressure: Float(pressure),
            tiltX: Float(tiltX),
            tiltY: Float(tiltY),
            rotation: Float(rotation),
            timestamp: time
        )
    }

    init(from decoder: Decoder) throws {
        var values = try decoder.unkeyedContainer()
        x = try values.decode(Double.self)
        y = try values.decode(Double.self)
        pressure = try values.decode(Double.self)
        tiltX = try values.decode(Double.self)
        tiltY = try values.decode(Double.self)
        rotation = try values.decode(Double.self)
        time = try values.decode(Double.self)
    }

    func encode(to encoder: Encoder) throws {
        var values = encoder.unkeyedContainer()
        for value in [x, y, pressure, tiltX, tiltY, rotation, time] {
            try values.encode(value)
        }
    }
}

extension SymmetryMode {
    var recordingKey: String {
        switch self {
        case .off: return "off"
        case .horizontal: return "horizontal"
        case .vertical: return "vertical"
        case .quad: return "quad"
        case .radial(let n): return "radial:\(n)"
        }
    }

    init(recordingKey: String) {
        switch recordingKey {
        case "horizontal": self = .horizontal
        case "vertical": self = .vertical
        case "quad": self = .quad
        case let key where key.hasPrefix("radial:"):
            self = .radial(Int(key.dropFirst("radial:".count)) ?? 2)
        default: self = .off
        }
    }
}

/// Captures every stroke drawn on one canvas into a `StrokeRecording`.
///
/// Off by default. Turn it on with
///
///     defaults write com.artsy.app recordStrokes -bool YES
///
/// and each canvas writes a JSON file to
/// `~/Library/Application Support/Artsy/Stroke Recordings/`. Copy a file into
/// `ArtsyTests/Recordings/` to have the test suite replay it.
final class StrokeRecorder {
    static var isEnabledInDefaults: Bool {
        UserDefaults.standard.bool(forKey: "recordStrokes")
    }

    private(set) var recording: StrokeRecording
    private var current: RecordedStroke?
    private var strokeStart: TimeInterval = 0
    private let fileURL: URL?
    private let writeQueue = DispatchQueue(label: "com.artsy.stroke-recorder", qos: .utility)

    /// - Parameter fileURL: where to save after each stroke; nil keeps the recording in memory only.
    init(canvasSize: CGSize, fileURL: URL?) {
        self.recording = StrokeRecording(canvasWidth: Int(canvasSize.width), canvasHeight: Int(canvasSize.height))
        self.fileURL = fileURL
        if let fileURL {
            fputs("Artsy: recording strokes to \(fileURL.path)\n", stderr)
        }
    }

    /// A fresh, timestamped file in the app's Application Support folder.
    static func newFileURL() -> URL? {
        guard let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            return nil
        }
        let folder = support.appendingPathComponent("Artsy/Stroke Recordings", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        } catch {
            fputs("Artsy: could not create \(folder.path): \(error.localizedDescription)\n", stderr)
            return nil
        }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH.mm.ss"
        let suffix = UUID().uuidString.prefix(4)
        return folder.appendingPathComponent("\(formatter.string(from: Date())) \(suffix).json")
    }

    func beginStroke(settingsFrom viewModel: CanvasViewModel, firstPoint: StrokePoint) {
        strokeStart = firstPoint.timestamp
        current = RecordedStroke(
            settingsFrom: viewModel,
            points: [RecordedPoint(firstPoint, strokeStart: strokeStart)]
        )
    }

    func append(_ point: StrokePoint) {
        current?.points.append(RecordedPoint(point, strokeStart: strokeStart))
    }

    func endStroke() {
        guard let stroke = current else { return }
        current = nil
        recording.strokes.append(stroke)
        save()
    }

    private func save() {
        guard let fileURL else { return }
        let snapshot = recording
        writeQueue.async {
            do {
                try JSONEncoder().encode(snapshot).write(to: fileURL, options: .atomic)
            } catch {
                fputs("Artsy: could not save stroke recording: \(error.localizedDescription)\n", stderr)
            }
        }
    }
}
