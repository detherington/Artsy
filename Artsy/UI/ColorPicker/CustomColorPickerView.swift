import SwiftUI
import ArtsyEngine
#if os(macOS)
#if canImport(AppKit)
import AppKit
#endif
#endif

/// Compact color picker shown in a popover. Continuous interaction (SV square,
/// hue slider, hex field) updates live; discrete selection (preset swatch,
/// recent swatch, eyedropper) commits and auto-dismisses via `onCommit`.
struct CustomColorPickerView: View {
    @Binding var color: StrokeColor
    var onCommit: () -> Void

    @ObservedObject private var prefs = AppPreferences.shared

    // Internal HSB state for UI interaction. Source of truth for what user sees.
    @State private var hue: Double = 0
    @State private var saturation: Double = 0
    @State private var brightness: Double = 0
    @State private var hexText: String = ""

    // Fixed palette — 4 rows × 8 columns
    private static let palette: [String] = [
        "#000000", "#333333", "#666666", "#999999", "#CCCCCC", "#FFFFFF", "#808080", "#1A1A1A",
        "#FF0000", "#FF6600", "#FFCC00", "#66CC00", "#00CC66", "#00CCCC", "#0066FF", "#6600FF",
        "#FF66CC", "#FFAA99", "#FFD699", "#FFFF99", "#CCFF99", "#99FFCC", "#99CCFF", "#CC99FF",
        "#8B0000", "#A0522D", "#B8860B", "#556B2F", "#2F4F4F", "#483D8B", "#4B0082", "#800080",
    ]

    var body: some View {
        VStack(spacing: 10) {
            // Top row: SV square + hue slider
            HStack(spacing: 8) {
                SVSquareView(hue: hue, saturation: $saturation, brightness: $brightness)
                    .frame(width: 180, height: 160)
                    .onChange(of: saturation) { _, _ in syncFromHSB() }
                    .onChange(of: brightness) { _, _ in syncFromHSB() }

                HueSliderView(hue: $hue)
                    .frame(width: 18, height: 160)
                    .onChange(of: hue) { _, _ in syncFromHSB() }
            }

            // Hex + eyedropper
            HStack(spacing: 6) {
                Text("#")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(.secondary)
                TextField("RRGGBB", text: $hexText)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 11, design: .monospaced))
                    .frame(width: 90)
                    .onSubmit {
                        if applyHex(hexText) {
                            commit()
                        }
                    }

                Spacer()

                #if os(macOS)
                Button(action: eyedrop) {
                    Image(systemName: "eyedropper")
                        .font(.system(size: 12))
                }
                .buttonStyle(.plain)
                .help("Pick from screen")
                #endif

                // Current color preview
                RoundedRectangle(cornerRadius: 3)
                    .fill(currentColor.displayColor)
                    .frame(width: 28, height: 20)
                    .overlay(
                        RoundedRectangle(cornerRadius: 3)
                            .stroke(Color.white.opacity(0.4), lineWidth: 1)
                    )
            }

            // Recent colors (only if any)
            if !prefs.recentColors.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text("RECENT")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundColor(.secondary)
                    HStack(spacing: 4) {
                        ForEach(prefs.recentColors, id: \.self) { hex in
                            swatchButton(hex: hex, size: 18)
                        }
                        Spacer()
                    }
                }
            }

            // Fixed palette
            VStack(alignment: .leading, spacing: 4) {
                Text("PALETTE")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundColor(.secondary)
                LazyVGrid(
                    columns: Array(repeating: GridItem(.fixed(20), spacing: 4), count: 8),
                    spacing: 4
                ) {
                    ForEach(Self.palette, id: \.self) { hex in
                        swatchButton(hex: hex, size: 20)
                    }
                }
            }
        }
        .padding(12)
        .frame(width: 240)
        .onAppear { syncFromStrokeColor() }
    }

    // MARK: - Swatch

    private func swatchButton(hex: String, size: CGFloat) -> some View {
        Button {
            if applyHex(hex) { commit() }
        } label: {
            RoundedRectangle(cornerRadius: 3)
                .fill((ColorMath.color(fromHex: hex) ?? .black).displayColor)
                .frame(width: size, height: size)
                .overlay(
                    RoundedRectangle(cornerRadius: 3)
                        .stroke(Color.white.opacity(0.2), lineWidth: 1)
                )
        }
        .buttonStyle(.plain)
        .help(hex)
    }

    // MARK: - Color sync

    private var currentColor: StrokeColor {
        ColorMath.color(hue: hue, saturation: saturation, brightness: brightness)
    }

    /// Called when the bound StrokeColor changes externally (on appear).
    private func syncFromStrokeColor() {
        let hsb = ColorMath.hsb(of: color)
        hue = hsb.hue
        saturation = hsb.saturation
        brightness = hsb.brightness
        hexText = ColorMath.hex(of: color)
    }

    /// Called when any HSB component changes — write back to the binding.
    private func syncFromHSB() {
        color = currentColor
        hexText = ColorMath.hex(of: color)
    }

    /// Apply a hex string. Returns true if valid.
    @discardableResult
    private func applyHex(_ hex: String) -> Bool {
        guard let parsed = ColorMath.color(fromHex: hex) else { return false }
        let hsb = ColorMath.hsb(of: parsed)
        hue = hsb.hue
        saturation = hsb.saturation
        brightness = hsb.brightness
        hexText = ColorMath.hex(of: parsed)
        color = parsed
        return true
    }

    private func commit() {
        prefs.pushRecentColor(hexText)
        onCommit()
    }

    // MARK: - Eyedropper

    #if os(macOS)
    private func eyedrop() {
        NSColorSampler().show { picked in
            guard let ns = picked else { return }
            if applyHex(ColorMath.hex(of: ns.strokeColor)) { commit() }
        }
    }
    #endif
}

// MARK: - SV Square

struct SVSquareView: View {
    let hue: Double
    @Binding var saturation: Double
    @Binding var brightness: Double

    var body: some View {
        GeometryReader { geo in
            ZStack {
                // Hue base
                Rectangle()
                    .fill(ColorMath.color(hue: hue, saturation: 1, brightness: 1).displayColor)

                // White-to-transparent horizontal (saturation)
                LinearGradient(
                    gradient: Gradient(colors: [.white, Color.white.opacity(0)]),
                    startPoint: .leading, endPoint: .trailing
                )

                // Transparent-to-black vertical (value)
                LinearGradient(
                    gradient: Gradient(colors: [Color.black.opacity(0), .black]),
                    startPoint: .top, endPoint: .bottom
                )

                // Cursor
                let cx = CGFloat(saturation) * geo.size.width
                let cy = (1 - CGFloat(brightness)) * geo.size.height
                Circle()
                    .stroke(Color.white, lineWidth: 2)
                    .frame(width: 10, height: 10)
                    .overlay(Circle().stroke(Color.black, lineWidth: 1))
                    .position(x: cx, y: cy)
                    .allowsHitTesting(false)
            }
            .cornerRadius(4)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        let x = max(0, min(geo.size.width, value.location.x))
                        let y = max(0, min(geo.size.height, value.location.y))
                        saturation = Double(x / geo.size.width)
                        brightness = Double(1 - y / geo.size.height)
                    }
            )
        }
    }
}

// MARK: - Hue Slider

struct HueSliderView: View {
    @Binding var hue: Double

    private static let hueColors: [Color] = stride(from: 0.0, through: 1.0, by: 1.0 / 12.0).map {
        ColorMath.color(hue: $0, saturation: 1, brightness: 1).displayColor
    }

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .topLeading) {
                LinearGradient(
                    gradient: Gradient(colors: Self.hueColors),
                    startPoint: .top, endPoint: .bottom
                )
                .cornerRadius(4)

                let cy = CGFloat(hue) * geo.size.height
                Rectangle()
                    .stroke(Color.white, lineWidth: 2)
                    .frame(width: geo.size.width + 4, height: 4)
                    .offset(x: -2, y: cy - 2)
                    .allowsHitTesting(false)
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        let y = max(0, min(geo.size.height, value.location.y))
                        hue = Double(y / geo.size.height)
                    }
            )
        }
    }
}
