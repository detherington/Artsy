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
        static let smoothingMode = "smoothingMode" // SmoothingMode raw value
        static let easeStrokesWithoutPressure = "easeStrokesWithoutPressure"
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

    /// Stroke smoothing algorithm. Starts on Adaptive: steady when slow, out of the way when fast.
    @Published var smoothingMode: SmoothingMode {
        didSet { defaults.set(smoothingMode.rawValue, forKey: Key.smoothingMode) }
    }

    /// Ease strokes in and out when the input has no pressure (mouse, trackpad).
    @Published var easeStrokesWithoutPressure: Bool {
        didSet { defaults.set(easeStrokesWithoutPressure, forKey: Key.easeStrokesWithoutPressure) }
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

        self.smoothingMode = defaults.string(forKey: Key.smoothingMode).flatMap(SmoothingMode.init(rawValue:)) ?? .oneEuro
        self.easeStrokesWithoutPressure = (defaults.object(forKey: Key.easeStrokesWithoutPressure) as? Bool) ?? true
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
