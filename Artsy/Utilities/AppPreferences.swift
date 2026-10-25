import Foundation
import SwiftUI

/// User-configurable defaults persisted to UserDefaults.
final class AppPreferences: ObservableObject {
    static let shared = AppPreferences()

    private let defaults = UserDefaults.standard

    // Keys
    private enum Key {
        static let defaultCanvasWidth = "defaultCanvasWidth"
        static let defaultCanvasHeight = "defaultCanvasHeight"
        static let skipNewCanvasDialog = "skipNewCanvasDialog"
        static let defaultBrushName = "defaultBrushName"
        static let defaultBrushSize = "defaultBrushSize"
        static let defaultCanvasBackground = "defaultCanvasBackground" // hex string
        static let recentColors = "recentColors" // [hex string]
        static let paletteColors = "paletteColors" // [hex string]
        static let smoothingMode = "smoothingMode" // SmoothingMode raw value
        static let pressureCurves = "pressureCurves" // JSON: [pen key: PressureCurve]
        static let easeStrokesWithoutPressure = "easeStrokesWithoutPressure"
        static let paintRelief = "paintRelief"
        static let paintGloss = "paintGloss"
        static let dryingTime = "dryingTime"
        static let snapShapesOnHold = "snapShapesOnHold"
        static let layersDocked = "layersDocked"
    }

    // MARK: - Published

    @Published var defaultCanvasWidth: Int {
        didSet { defaults.set(defaultCanvasWidth, forKey: Key.defaultCanvasWidth) }
    }

    @Published var defaultCanvasHeight: Int {
        didSet { defaults.set(defaultCanvasHeight, forKey: Key.defaultCanvasHeight) }
    }

    @Published var skipNewCanvasDialog: Bool {
        didSet { defaults.set(skipNewCanvasDialog, forKey: Key.skipNewCanvasDialog) }
    }

    @Published var defaultBrushName: String {
        didSet { defaults.set(defaultBrushName, forKey: Key.defaultBrushName) }
    }

    @Published var defaultBrushSize: Double {
        didSet { defaults.set(defaultBrushSize, forKey: Key.defaultBrushSize) }
    }

    /// Hex string ("#FFFFFF", "#000000", or "transparent")
    @Published var defaultCanvasBackground: String {
        didSet { defaults.set(defaultCanvasBackground, forKey: Key.defaultCanvasBackground) }
    }

    /// Most recently used colors, stored as hex strings (e.g. "#FF00AA"). Max 8.
    @Published var recentColors: [String] {
        didSet { defaults.set(recentColors, forKey: Key.recentColors) }
    }

    /// The palette the painter keeps in the colour panel, hex strings; starts with a few.
    @Published var paletteColors: [String] {
        didSet { defaults.set(paletteColors, forKey: Key.paletteColors) }
    }
    static let startingPalette = [
        "000000", "4D4D4D", "999999", "FFFFFF", "C0392B", "E67E22", "F1C40F", "27AE60",
        "16A085", "2980B9", "8E44AD", "D35400", "F5CBA7", "7F8C8D", "2C3E50", "FADBD8",
    ]

    /// Stroke smoothing algorithm. Starts on Adaptive: steady when slow, out of the way when fast.
    @Published var smoothingMode: SmoothingMode {
        didSet { defaults.set(smoothingMode.rawValue, forKey: Key.smoothingMode) }
    }

    /// Ease strokes in and out when the input has no pressure (mouse, trackpad).
    @Published var easeStrokesWithoutPressure: Bool {
        didSet { defaults.set(easeStrokesWithoutPressure, forKey: Key.easeStrokesWithoutPressure) }
    }

    /// How strongly thick paint (impasto) is lit on the canvas and in exports; 0 shows it flat.
    @Published var paintRelief: Double {
        didSet { defaults.set(paintRelief, forKey: Key.paintRelief) }
    }

    /// The paint's finish, 0 matte to 1 glossy: a tight glint or a broad sheen on thick paint.
    @Published var paintGloss: Double {
        didSet { defaults.set(paintGloss, forKey: Key.paintGloss) }
    }

    /// How long wet paint (Oil, Watercolor) stays wet, seconds; a brush's own wetness is a
    /// share of it.
    @Published var dryingTime: Double {
        didSet { defaults.set(dryingTime, forKey: Key.dryingTime) }
    }

    /// Hold the pen still at the end of a stroke to snap it to the shape it was going for.
    @Published var snapShapesOnHold: Bool {
        didSet { defaults.set(snapShapesOnHold, forKey: Key.snapShapesOnHold) }
    }

    /// Layers in a dock beside the canvas on a wide window, rather than a pop-up.
    @Published var layersDocked: Bool {
        didSet { defaults.set(layersDocked, forKey: Key.layersDocked) }
    }

    /// Pressure curves by pen (see `TabletEventHandler.currentPenKey`). A pen that has none
    /// saved uses the linear curve.
    @Published var pressureCurves: [String: PressureCurve] {
        didSet {
            if let data = try? JSONEncoder().encode(pressureCurves) {
                defaults.set(data, forKey: Key.pressureCurves)
            }
        }
    }

    func pressureCurve(forPen key: String) -> PressureCurve {
        pressureCurves[key] ?? .linear
    }

    // MARK: - Init

    private init() {
        let w = defaults.integer(forKey: Key.defaultCanvasWidth)
        let h = defaults.integer(forKey: Key.defaultCanvasHeight)
        self.defaultCanvasWidth = w > 0 ? w : 2048
        self.defaultCanvasHeight = h > 0 ? h : 2048

        self.skipNewCanvasDialog = defaults.bool(forKey: Key.skipNewCanvasDialog)
        self.defaultBrushName = defaults.string(forKey: Key.defaultBrushName) ?? "Hard Round"

        let savedSize = defaults.double(forKey: Key.defaultBrushSize)
        self.defaultBrushSize = savedSize > 0 ? savedSize : 12

        self.defaultCanvasBackground = defaults.string(forKey: Key.defaultCanvasBackground) ?? "#FFFFFF"

        self.recentColors = (defaults.array(forKey: Key.recentColors) as? [String]) ?? []
        self.paletteColors = (defaults.array(forKey: Key.paletteColors) as? [String]) ?? Self.startingPalette

        self.smoothingMode = defaults.string(forKey: Key.smoothingMode).flatMap(SmoothingMode.init(rawValue:)) ?? .oneEuro
        self.easeStrokesWithoutPressure = (defaults.object(forKey: Key.easeStrokesWithoutPressure) as? Bool) ?? true
        self.paintRelief = min(max((defaults.object(forKey: Key.paintRelief) as? Double) ?? 1.0, 0), 2)
        self.paintGloss = min(max((defaults.object(forKey: Key.paintGloss) as? Double) ?? 0.5, 0), 1)
        self.dryingTime = min(max((defaults.object(forKey: Key.dryingTime) as? Double) ?? 60, 5), 600)
        self.snapShapesOnHold = (defaults.object(forKey: Key.snapShapesOnHold) as? Bool) ?? true
        self.layersDocked = (defaults.object(forKey: Key.layersDocked) as? Bool) ?? true
        self.pressureCurves = defaults.data(forKey: Key.pressureCurves)
            .flatMap { try? JSONDecoder().decode([String: PressureCurve].self, from: $0) } ?? [:]
    }

    func pushRecentColor(_ hex: String) {
        let normalized = hex.uppercased()
        var list = recentColors.filter { $0.uppercased() != normalized }
        list.insert(normalized, at: 0)
        if list.count > 8 { list = Array(list.prefix(8)) }
        recentColors = list
    }

    // MARK: - Convenience

    var defaultCanvasSize: CGSize {
        CGSize(width: defaultCanvasWidth, height: defaultCanvasHeight)
    }

    /// Find the BrushDescriptor matching the saved name, falling back to .hardRound.
    var defaultBrush: BrushDescriptor {
        BrushLibrary.shared.brush(named: defaultBrushName) ?? .hardRound
    }
}
