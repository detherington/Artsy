import SwiftUI

struct CanvasSizePreset: Identifiable {
    let id = UUID()
    let name: String
    let width: Int
    let height: Int

    var label: String { "\(name) (\(width)×\(height))" }

    static let presets: [CanvasSizePreset] = [
        .init(name: "Small", width: 1024, height: 1024),
        .init(name: "Medium", width: 2048, height: 2048),
        .init(name: "Large", width: 4096, height: 4096),
        .init(name: "HD Landscape", width: 1920, height: 1080),
        .init(name: "HD Portrait", width: 1080, height: 1920),
        .init(name: "A4 @ 300dpi", width: 2480, height: 3508),
    ]
}

struct NewCanvasView: View {
    @State private var selectedPreset: CanvasSizePreset?
    @State private var customWidth: String
    @State private var customHeight: String
    @State private var useCustom: Bool

    let onCreate: (CGSize) -> Void
    let onOpen: (() -> Void)?
    let onCancel: () -> Void

    init(onCreate: @escaping (CGSize) -> Void, onOpen: (() -> Void)?, onCancel: @escaping () -> Void) {
        self.onCreate = onCreate
        self.onOpen = onOpen
        self.onCancel = onCancel

        // Initialize from user preferences — pick a preset that matches, or use custom
        let prefs = AppPreferences.shared
        let defW = prefs.defaultCanvasWidth
        let defH = prefs.defaultCanvasHeight
        if let match = CanvasSizePreset.presets.first(where: { $0.width == defW && $0.height == defH }) {
            _selectedPreset = State(initialValue: match)
            _useCustom = State(initialValue: false)
        } else {
            _selectedPreset = State(initialValue: CanvasSizePreset.presets[1])
            _useCustom = State(initialValue: true)
        }
        _customWidth = State(initialValue: "\(defW)")
        _customHeight = State(initialValue: "\(defH)")
    }

    private var resolvedSize: CGSize {
        if useCustom {
            let w = max(64, min(8192, Int(customWidth) ?? 2048))
            let h = max(64, min(8192, Int(customHeight) ?? 2048))
            return CGSize(width: w, height: h)
        } else if let preset = selectedPreset {
            return CGSize(width: preset.width, height: preset.height)
        }
        return CGSize(width: 2048, height: 2048)
    }

    var body: some View {
        VStack(spacing: 16) {
            Text("New Canvas")
                .font(.headline)

            // Presets
            VStack(alignment: .leading, spacing: 4) {
                Text("Presets")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(.secondary)

                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 6) {
                    ForEach(CanvasSizePreset.presets) { preset in
                        Button(action: {
                            selectedPreset = preset
                            useCustom = false
                            customWidth = "\(preset.width)"
                            customHeight = "\(preset.height)"
                        }) {
                            VStack(spacing: 2) {
                                Text(preset.name)
                                    .font(.system(size: 11, weight: .medium))
                                Text("\(preset.width) × \(preset.height)")
                                    .font(.system(size: 9, design: .monospaced))
                                    .foregroundColor(.secondary)
                            }
                            .frame(maxWidth: .infinity, minHeight: 40)
                            .background(
                                !useCustom && selectedPreset?.name == preset.name
                                    ? Color.accentColor.opacity(0.2)
                                    : Color(nsColor: .controlBackgroundColor)
                            )
                            .cornerRadius(6)
                            .overlay(
                                RoundedRectangle(cornerRadius: 6)
                                    .stroke(
                                        !useCustom && selectedPreset?.name == preset.name
                                            ? Color.accentColor
                                            : Color.clear,
                                        lineWidth: 1.5
                                    )
                            )
                        }
                        .buttonStyle(.plain)
                    }
                }
            }

            Divider()

            // Custom size
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("Custom Size")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(.secondary)
                    Spacer()
                    Toggle("", isOn: $useCustom)
                        .toggleStyle(.switch)
                        .controlSize(.small)
                }

                HStack(spacing: 12) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Width")
                            .font(.system(size: 10))
                            .foregroundColor(.secondary)
                        TextField("Width", text: $customWidth)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 80)
                            .disabled(!useCustom)
                    }

                    Text("×")
                        .foregroundColor(.secondary)

                    VStack(alignment: .leading, spacing: 2) {
                        Text("Height")
                            .font(.system(size: 10))
                            .foregroundColor(.secondary)
                        TextField("Height", text: $customHeight)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 80)
                            .disabled(!useCustom)
                    }

                    Spacer()
                }

                if useCustom {
                    Text("Max 8192 × 8192")
                        .font(.system(size: 9))
                        .foregroundColor(.secondary)
                }
            }

            Divider()

            // Summary + buttons
            Text("Canvas: \(Int(resolvedSize.width)) × \(Int(resolvedSize.height)) px")
                .font(.system(size: 11, design: .monospaced))
                .foregroundColor(.secondary)

            HStack {
                Button("Cancel", action: onCancel)
                    .keyboardShortcut(.cancelAction)
                Spacer()
                if let onOpen = onOpen {
                    Button("Open Existing...") {
                        onOpen()
                    }
                    .keyboardShortcut("o", modifiers: .command)
                }
                Button("Create") {
                    onCreate(resolvedSize)
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 360)
    }
}
