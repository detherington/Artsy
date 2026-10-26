#if canImport(AppKit)
import AppKit
#endif
import SwiftUI
import ArtsyEngine

/// The colour panel: a saturation square with a hue strip beside it, the colour being
/// made next to the one the panel opened with, fields for the keyboard, the recent
/// colours, and a palette the painter keeps. A swatch picks and closes; the square and
/// the strip keep the panel open while the pen moves.
struct ColorPanelView: View {
    @Binding var color: StrokeColor
    @ObservedObject var viewModel: CanvasViewModel
    let dismiss: () -> Void
    @ObservedObject private var prefs = AppPreferences.shared

    @State private var hue: Double = 0
    @State private var saturation: Double = 0
    @State private var brightness: Double = 0
    @State private var hexText = ""
    @State private var hueText = ""
    @State private var saturationText = ""
    @State private var brightnessText = ""
    /// The colour the panel opened with, to go back to.
    @State private var previous: StrokeColor

    static let squareSize: CGFloat = 260
    static let stripWidth: CGFloat = 32
    static let swatch: CGFloat = 32

    init(color: Binding<StrokeColor>, viewModel: CanvasViewModel, dismiss: @escaping () -> Void) {
        self._color = color
        self.viewModel = viewModel
        self.dismiss = dismiss
        _previous = State(initialValue: color.wrappedValue)
    }

    var body: some View {
        VStack(spacing: 0) {
            PanelHeader("Colour") {
                HStack(spacing: 6) {
                    #if os(macOS)
                    Button(action: sampleScreen) {
                        Image(systemName: "scope")
                            .font(.system(size: 14))
                            .frame(width: 32, height: 32)
                            .background(Capsule().fill(Chrome.control))
                    }
                    .buttonStyle(.plain)
                    .foregroundColor(Chrome.text)
                    .help("Pick a colour from anywhere on the screen")
                    #endif
                    Button(action: {
                        viewModel.currentTool = .eyedropper
                        dismiss()
                    }) {
                        Image(systemName: "eyedropper")
                            .font(.system(size: 14))
                            .frame(width: 32, height: 32)
                            .background(Capsule().fill(Chrome.control))
                    }
                    .buttonStyle(.plain)
                    .foregroundColor(Chrome.text)
                    .help("Pick a colour from the canvas with the pen (I)")
                }
            }
            Divider().overlay(Chrome.hairline)

            // The square and the strip take the pen's drag themselves, so they sit outside
            // the scrolling part
            HStack(spacing: 12) {
                SVSquareView(hue: hue, saturation: $saturation, brightness: $brightness)
                    .frame(width: Self.squareSize, height: Self.squareSize)
                    .onChange(of: saturation) { _, _ in syncFromHSB() }
                    .onChange(of: brightness) { _, _ in syncFromHSB() }
                HueSliderView(hue: $hue)
                    .frame(width: Self.stripWidth, height: Self.squareSize)
                    .onChange(of: hue) { _, _ in syncFromHSB() }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 12)

            // The colour being made, and the one the panel opened with
            HStack(spacing: 0) {
                ColorWell(color: color, label: "Now", isCurrent: true) {}
                ColorWell(color: previous, label: "Before", isCurrent: false) {
                    apply(previous)
                }
            }
            .padding(.horizontal, 12)
            .frame(height: Chrome.target)

            DragScroll {
                VStack(spacing: 0) {
                    fields
                    if !prefs.recentColors.isEmpty {
                        PanelSectionLabel("Recent")
                        swatchRow(prefs.recentColors.compactMap(ColorMath.color(fromHex:)))
                    }
                    PanelSectionLabel("Palette")
                    palette
                        .padding(.bottom, 12)
                }
            }
        }
        .frame(width: Chrome.panelWidth, height: 640)
        .background(Chrome.panel)
        .onAppear { syncFromColor() }
        .onDisappear {
            // Whatever the pen settled on is worth remembering
            if color != previous { prefs.pushRecentColor(ColorMath.hex(of: color)) }
        }
    }

    // MARK: - Fields

    private var fields: some View {
        HStack(spacing: 6) {
            field("H", text: $hueText) { ColorMath.applying(hue: $0, to: &hue) }
            field("S", text: $saturationText) { ColorMath.applying(percent: $0, to: &saturation) }
            field("B", text: $brightnessText) { ColorMath.applying(percent: $0, to: &brightness) }
            Spacer(minLength: 2)
            Text("#")
                .font(Chrome.valueFont)
                .foregroundColor(Chrome.secondaryText)
                .fixedSize()
            TextField("RRGGBB", text: $hexText)
                .textFieldStyle(.roundedBorder)
                .font(Chrome.valueFont)
                .frame(width: 68)
                .onSubmit {
                    if let picked = ColorMath.color(fromHex: hexText) { apply(picked) }
                }
        }
        .padding(.horizontal, 14)
        .frame(height: Chrome.target)
    }

    private func field(_ label: String, text: Binding<String>, submit: @escaping (String) -> Bool) -> some View {
        HStack(spacing: 3) {
            Text(label)
                .font(Chrome.valueFont)
                .foregroundColor(Chrome.secondaryText)
                .fixedSize()
            TextField("", text: text)
                .textFieldStyle(.roundedBorder)
                .font(Chrome.valueFont)
                .frame(width: 40)
                .onSubmit { if submit(text.wrappedValue) { syncFromHSB() } }
        }
    }

    // MARK: - Swatches

    private func swatchRow(_ colors: [StrokeColor]) -> some View {
        HStack(spacing: 6) {
            ForEach(Array(colors.enumerated()), id: \.offset) { _, swatch in
                swatchButton(swatch)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 6)
    }

    private func swatchButton(_ swatch: StrokeColor) -> some View {
        Button(action: { pick(swatch) }) {
            RoundedRectangle(cornerRadius: 6)
                .fill(swatch.swiftUIColor)
                .frame(width: Self.swatch, height: Self.swatch)
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.white.opacity(swatch == color ? 0.9 : 0.2), lineWidth: 1.5))
                .contentShape(RoundedRectangle(cornerRadius: 6))
        }
        .buttonStyle(.plain)
        .help(ColorMath.hex(of: swatch))
    }

    private var palette: some View {
        let colors = prefs.paletteColors.compactMap(ColorMath.color(fromHex:))
        return LazyVGrid(columns: Array(repeating: GridItem(.fixed(Self.swatch), spacing: 6), count: 8), alignment: .leading, spacing: 6) {
            ForEach(Array(colors.enumerated()), id: \.offset) { index, swatch in
                swatchButton(swatch)
                    .contextMenu {
                        Button("Replace with Current Colour") { ColorPanelActions.replace(at: index, with: color, in: prefs) }
                        Button("Remove") { ColorPanelActions.remove(at: index, in: prefs) }
                    }
            }
            Button(action: { ColorPanelActions.add(color, to: prefs) }) {
                RoundedRectangle(cornerRadius: 6)
                    .strokeBorder(Chrome.hairline, style: StrokeStyle(lineWidth: 1.5, dash: [4, 3]))
                    .frame(width: Self.swatch, height: Self.swatch)
                    .overlay(Image(systemName: "plus").font(.system(size: 14, weight: .semibold)).foregroundColor(Chrome.secondaryText))
                    .contentShape(RoundedRectangle(cornerRadius: 6))
            }
            .buttonStyle(.plain)
            .help("Keep the current colour in the palette")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 6)
    }

    // MARK: - The colour

    /// A discrete pick: the colour, remembered, and the panel closes so the pen can paint.
    private func pick(_ swatch: StrokeColor) {
        apply(swatch)
        prefs.pushRecentColor(ColorMath.hex(of: swatch))
        dismiss()
    }

    private func apply(_ picked: StrokeColor) {
        color = picked
        syncFromColor()
    }

    private func syncFromColor() {
        let (h, s, b) = ColorMath.hsb(of: color)
        hue = h
        saturation = s
        brightness = b
        syncText()
    }

    private func syncFromHSB() {
        color = ColorMath.color(hue: hue, saturation: saturation, brightness: brightness)
        syncText()
    }

    private func syncText() {
        hexText = ColorMath.hex(of: color)
        hueText = "\(Int((hue * 360).rounded()) % 360)"
        saturationText = "\(Int((saturation * 100).rounded()))"
        brightnessText = "\(Int((brightness * 100).rounded()))"
    }

    private func sampleScreen() {
        #if os(macOS)
        NSColorSampler().show { picked in
            guard let picked else { return }
            pick(picked.strokeColor)
        }
        #endif
    }
}

/// A colour with its name under it, half a row wide.
struct ColorWell: View {
    let color: StrokeColor
    let label: String
    let isCurrent: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                RoundedRectangle(cornerRadius: 8)
                    .fill(color.swiftUIColor)
                    .frame(width: 44, height: 32)
                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.white.opacity(isCurrent ? 0.7 : 0.25), lineWidth: 1.5))
                Text(label)
                    .font(Chrome.font)
                    .foregroundColor(isCurrent ? Chrome.text : Chrome.secondaryText)
                Spacer()
            }
            .padding(.horizontal, 4)
            .frame(maxWidth: .infinity)
            .frame(height: Chrome.target)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(isCurrent)
        .help(isCurrent ? "The colour now" : "Back to the colour the panel opened with")
    }
}

/// The palette's edits, apart from the views so they can be tested without them.
enum ColorPanelActions {
    static let paletteLimit = 32

    static func add(_ color: StrokeColor, to prefs: AppPreferences) {
        let hex = ColorMath.hex(of: color)
        guard !prefs.paletteColors.contains(hex), prefs.paletteColors.count < paletteLimit else { return }
        prefs.paletteColors.append(hex)
    }

    static func replace(at index: Int, with color: StrokeColor, in prefs: AppPreferences) {
        guard prefs.paletteColors.indices.contains(index) else { return }
        prefs.paletteColors[index] = ColorMath.hex(of: color)
    }

    static func remove(at index: Int, in prefs: AppPreferences) {
        guard prefs.paletteColors.indices.contains(index) else { return }
        prefs.paletteColors.remove(at: index)
    }
}

/// Between the engine's Display P3 colour and what the panel shows and reads.
enum ColorMath {
    /// The components' hue, saturation and brightness, as the toolkits compute them: a
    /// grey has no hue, black no saturation.
    static func hsb(of color: StrokeColor) -> (hue: Double, saturation: Double, brightness: Double) {
        let r = Double(color.red), g = Double(color.green), b = Double(color.blue)
        let high = max(r, g, b), low = min(r, g, b), spread = high - low
        var hue = 0.0
        if spread > 0 {
            if high == r { hue = (g - b) / spread }
            else if high == g { hue = (b - r) / spread + 2 }
            else { hue = (r - g) / spread + 4 }
            hue /= 6
            if hue < 0 { hue += 1 }
        }
        return (hue, high > 0 ? spread / high : 0, high)
    }

    static func color(hue: Double, saturation: Double, brightness: Double) -> StrokeColor {
        let turn = (hue - floor(hue)) * 6
        let sector = Int(turn), f = turn - Double(sector)
        let v = brightness
        let p = v * (1 - saturation), q = v * (1 - saturation * f), t = v * (1 - saturation * (1 - f))
        let (r, g, b): (Double, Double, Double)
        switch sector {
        case 0: (r, g, b) = (v, t, p)
        case 1: (r, g, b) = (q, v, p)
        case 2: (r, g, b) = (p, v, t)
        case 3: (r, g, b) = (p, q, v)
        case 4: (r, g, b) = (t, p, v)
        default: (r, g, b) = (v, p, q)
        }
        return StrokeColor(red: Float(r), green: Float(g), blue: Float(b), alpha: 1)
    }

    static func hex(of color: StrokeColor) -> String {
        func byte(_ v: Float) -> Int { Int((max(0, min(1, v)) * 255).rounded()) }
        return String(format: "%02X%02X%02X", byte(color.red), byte(color.green), byte(color.blue))
    }

    /// "#RRGGBB" or "RRGGBB" as a colour in Display P3.
    static func color(fromHex hex: String) -> StrokeColor? {
        var s = hex.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        if s.hasPrefix("#") { s.removeFirst() }
        guard s.count == 6, let v = UInt32(s, radix: 16) else { return nil }
        return StrokeColor(red: Float((v >> 16) & 0xFF) / 255, green: Float((v >> 8) & 0xFF) / 255,
                           blue: Float(v & 0xFF) / 255, alpha: 1)
    }

    /// Degrees typed into the hue field, into a hue; false if it was not a number.
    static func applying(hue text: String, to hue: inout Double) -> Bool {
        guard let degrees = Double(text.trimmingCharacters(in: .whitespaces)) else { return false }
        hue = (degrees.truncatingRemainder(dividingBy: 360) + 360).truncatingRemainder(dividingBy: 360) / 360
        return true
    }

    /// A percentage typed into a field, into a 0...1 value; false if it was not a number.
    static func applying(percent text: String, to value: inout Double) -> Bool {
        guard let percent = Double(text.trimmingCharacters(in: .whitespaces)) else { return false }
        value = min(max(percent, 0), 100) / 100
        return true
    }
}
