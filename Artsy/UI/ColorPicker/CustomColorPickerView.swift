import SwiftUI
import AppKit

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

                Button(action: eyedrop) {
                    Image(systemName: "eyedropper")
                        .font(.system(size: 12))
                }
                .buttonStyle(.plain)
                .help("Pick from screen")

                // Current color preview
                RoundedRectangle(cornerRadius: 3)
                    .fill(Color(nsColor: currentNSColor))
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
                .fill(Color(nsColor: NSColor.fromHex(hex) ?? .black))
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

    private var currentNSColor: NSColor {
        NSColor(colorSpace: .displayP3, hue: CGFloat(hue), saturation: CGFloat(saturation),
                brightness: CGFloat(brightness), alpha: 1.0)
    }

    /// Called when the bound StrokeColor changes externally (on appear).
    private func syncFromStrokeColor() {
        let ns = NSColor(displayP3Red: CGFloat(color.red), green: CGFloat(color.green),
                         blue: CGFloat(color.blue), alpha: CGFloat(color.alpha))
        var h: CGFloat = 0, s: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        ns.getHue(&h, saturation: &s, brightness: &b, alpha: &a)
        hue = Double(h)
        saturation = Double(s)
        brightness = Double(b)
        hexText = hexString(from: ns)
    }

    /// Called when any HSB component changes — write back to the binding.
    private func syncFromHSB() {
        let ns = currentNSColor
        color = StrokeColor(
            red: Float(ns.redComponent),
            green: Float(ns.greenComponent),
            blue: Float(ns.blueComponent),
            alpha: 1.0
        )
        hexText = hexString(from: ns)
    }

    /// Apply a hex string. Returns true if valid.
    @discardableResult
    private func applyHex(_ hex: String) -> Bool {
        guard let ns = NSColor.fromHex(hex) else { return false }
        var h: CGFloat = 0, s: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        let p3 = ns.usingColorSpace(.displayP3) ?? ns
        p3.getHue(&h, saturation: &s, brightness: &b, alpha: &a)
        hue = Double(h)
        saturation = Double(s)
        brightness = Double(b)
        hexText = hexString(from: p3)
        color = StrokeColor(
            red: Float(p3.redComponent),
            green: Float(p3.greenComponent),
            blue: Float(p3.blueComponent),
            alpha: 1.0
        )
        return true
    }

    private func commit() {
        prefs.pushRecentColor(hexText)
        onCommit()
    }

    // MARK: - Eyedropper

    private func eyedrop() {
        NSColorSampler().show { picked in
            guard let ns = picked else { return }
            let hex = hexString(from: ns.usingColorSpace(.displayP3) ?? ns)
            if applyHex(hex) { commit() }
        }
    }

    // MARK: - Hex helpers

    private func hexString(from ns: NSColor) -> String {
        let p3 = ns.usingColorSpace(.displayP3) ?? ns
        let r = Int((max(0, min(1, p3.redComponent)) * 255).rounded())
        let g = Int((max(0, min(1, p3.greenComponent)) * 255).rounded())
        let b = Int((max(0, min(1, p3.blueComponent)) * 255).rounded())
        return String(format: "%02X%02X%02X", r, g, b)
    }
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
                    .fill(Color(nsColor: NSColor(colorSpace: .displayP3, hue: CGFloat(hue),
                                                 saturation: 1, brightness: 1, alpha: 1)))

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
        Color(nsColor: NSColor(colorSpace: .displayP3, hue: CGFloat($0), saturation: 1,
                               brightness: 1, alpha: 1))
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

// MARK: - NSColor hex

extension NSColor {
    /// Parse "#RRGGBB" or "RRGGBB" as a Display P3 color.
    static func fromHex(_ hex: String) -> NSColor? {
        var s = hex.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        if s.hasPrefix("#") { s.removeFirst() }
        guard s.count == 6, let v = UInt32(s, radix: 16) else { return nil }
        let r = CGFloat((v >> 16) & 0xFF) / 255.0
        let g = CGFloat((v >> 8) & 0xFF) / 255.0
        let b = CGFloat(v & 0xFF) / 255.0
        return NSColor(colorSpace: .displayP3, components: [r, g, b, 1.0], count: 4)
    }
}
