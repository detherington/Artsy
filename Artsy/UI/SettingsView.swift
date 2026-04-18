import SwiftUI

struct SettingsView: View {
    @State private var selectedTab = 0
    @State private var openAIKey: String = ""
    @State private var googleKey: String = ""
    @State private var unsplashKey: String = ""
    @State private var openAIKeySaved = false
    @State private var googleKeySaved = false
    @State private var unsplashKeySaved = false

    var body: some View {
        TabView(selection: $selectedTab) {
            // AI tab
            VStack(alignment: .leading, spacing: 16) {
                Text("API Keys")
                    .font(.headline)

                Text("Keys are stored securely in macOS Keychain.")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)

                GroupBox("OpenAI") {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            SecureField("sk-...", text: $openAIKey)
                                .textFieldStyle(.roundedBorder)
                            Button(openAIKeySaved ? "Saved" : "Save") {
                                saveOpenAIKey()
                            }
                            .disabled(openAIKey.isEmpty)
                        }
                        if KeychainManager.shared.getAPIKey(for: .openAI) != nil {
                            HStack {
                                Image(systemName: "checkmark.circle.fill")
                                    .foregroundColor(.green)
                                    .font(.system(size: 11))
                                Text("Key configured")
                                    .font(.system(size: 11))
                                    .foregroundColor(.secondary)
                                Spacer()
                                Button("Remove") {
                                    try? KeychainManager.shared.deleteAPIKey(for: .openAI)
                                    openAIKey = ""
                                    openAIKeySaved = false
                                }
                                .font(.system(size: 11))
                            }
                        }
                    }
                    .padding(4)
                }

                GroupBox("Google (Gemini / Imagen)") {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            SecureField("AI...", text: $googleKey)
                                .textFieldStyle(.roundedBorder)
                            Button(googleKeySaved ? "Saved" : "Save") {
                                saveGoogleKey()
                            }
                            .disabled(googleKey.isEmpty)
                        }
                        if KeychainManager.shared.getAPIKey(for: .google) != nil {
                            HStack {
                                Image(systemName: "checkmark.circle.fill")
                                    .foregroundColor(.green)
                                    .font(.system(size: 11))
                                Text("Key configured")
                                    .font(.system(size: 11))
                                    .foregroundColor(.secondary)
                                Spacer()
                                Button("Remove") {
                                    try? KeychainManager.shared.deleteAPIKey(for: .google)
                                    googleKey = ""
                                    googleKeySaved = false
                                }
                                .font(.system(size: 11))
                            }
                        }
                    }
                    .padding(4)
                }

                GroupBox("Unsplash") {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            SecureField("Access key", text: $unsplashKey)
                                .textFieldStyle(.roundedBorder)
                            Button(unsplashKeySaved ? "Saved" : "Save") {
                                saveUnsplashKey()
                            }
                            .disabled(unsplashKey.isEmpty)
                        }
                        if KeychainManager.shared.getAPIKey(for: .unsplash) != nil {
                            HStack {
                                Image(systemName: "checkmark.circle.fill")
                                    .foregroundColor(.green)
                                    .font(.system(size: 11))
                                Text("Key configured")
                                    .font(.system(size: 11))
                                    .foregroundColor(.secondary)
                                Spacer()
                                Button("Remove") {
                                    try? KeychainManager.shared.deleteAPIKey(for: .unsplash)
                                    unsplashKey = ""
                                    unsplashKeySaved = false
                                }
                                .font(.system(size: 11))
                            }
                        }
                        Text("Use your Unsplash app's Access Key — not the Secret Key.")
                            .font(.system(size: 10))
                            .foregroundColor(.secondary)
                    }
                    .padding(4)
                }

                Spacer()
            }
            .padding(20)
            .tabItem { Label("AI", systemImage: "sparkles") }
            .tag(0)

            // General tab
            GeneralSettingsView()
            .tabItem { Label("General", systemImage: "gear") }
            .tag(1)

            // Tablet tab
            VStack(alignment: .leading, spacing: 16) {
                Text("Tablet")
                    .font(.headline)

                GroupBox("Pressure") {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Pressure curve and smoothing can be adjusted in the brush settings panel on the right sidebar.")
                            .font(.system(size: 11))
                            .foregroundColor(.secondary)

                        Text("Pen flip to eraser is automatically detected for Wacom and compatible tablets.")
                            .font(.system(size: 11))
                            .foregroundColor(.secondary)
                    }
                    .padding(4)
                }

                Spacer()
            }
            .padding(20)
            .tabItem { Label("Tablet", systemImage: "pencil.tip") }
            .tag(2)
        }
        .frame(width: 480, height: 520)
        .onAppear {
            openAIKeySaved = KeychainManager.shared.getAPIKey(for: .openAI) != nil
            googleKeySaved = KeychainManager.shared.getAPIKey(for: .google) != nil
            unsplashKeySaved = KeychainManager.shared.getAPIKey(for: .unsplash) != nil
        }
    }

    private func saveOpenAIKey() {
        try? KeychainManager.shared.setAPIKey(openAIKey, for: .openAI)
        openAIKeySaved = true
        openAIKey = ""
    }

    private func saveGoogleKey() {
        try? KeychainManager.shared.setAPIKey(googleKey, for: .google)
        googleKeySaved = true
        googleKey = ""
    }

    private func saveUnsplashKey() {
        try? KeychainManager.shared.setAPIKey(unsplashKey, for: .unsplash)
        unsplashKeySaved = true
        unsplashKey = ""
    }
}

// MARK: - General Settings

struct GeneralSettingsView: View {
    @ObservedObject private var prefs = AppPreferences.shared

    @State private var customWidth: String = ""
    @State private var customHeight: String = ""

    private var matchingPreset: CanvasSizePreset? {
        CanvasSizePreset.presets.first { $0.width == prefs.defaultCanvasWidth && $0.height == prefs.defaultCanvasHeight }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("General")
                    .font(.headline)

                GroupBox("New Canvas") {
                    VStack(alignment: .leading, spacing: 12) {
                        // Default canvas size preset picker
                        VStack(alignment: .leading, spacing: 6) {
                            Text("Default canvas size")
                                .font(.system(size: 11, weight: .medium))

                            Picker("", selection: Binding(
                                get: { matchingPreset?.id ?? UUID() },
                                set: { newID in
                                    if let p = CanvasSizePreset.presets.first(where: { $0.id == newID }) {
                                        prefs.defaultCanvasWidth = p.width
                                        prefs.defaultCanvasHeight = p.height
                                        customWidth = "\(p.width)"
                                        customHeight = "\(p.height)"
                                    }
                                }
                            )) {
                                ForEach(CanvasSizePreset.presets) { preset in
                                    Text("\(preset.name) (\(preset.width)×\(preset.height))").tag(preset.id)
                                }
                                Text("Custom").tag(UUID())
                            }
                            .pickerStyle(.menu)
                            .labelsHidden()

                            // Custom dimensions
                            HStack(spacing: 8) {
                                Text("Custom:")
                                    .font(.system(size: 11))
                                    .foregroundColor(.secondary)
                                TextField("Width", text: $customWidth)
                                    .frame(width: 70)
                                    .textFieldStyle(.roundedBorder)
                                    .onSubmit { commitCustom() }
                                Text("×")
                                    .foregroundColor(.secondary)
                                TextField("Height", text: $customHeight)
                                    .frame(width: 70)
                                    .textFieldStyle(.roundedBorder)
                                    .onSubmit { commitCustom() }
                                Button("Apply") { commitCustom() }
                                    .controlSize(.small)
                            }
                        }

                        Divider()

                        Toggle("Skip new canvas dialog on launch", isOn: $prefs.skipNewCanvasDialog)
                            .font(.system(size: 11))
                        Text("If enabled, opens a new canvas at the default size immediately when launching.")
                            .font(.system(size: 10))
                            .foregroundColor(.secondary)
                    }
                    .padding(4)
                }

                GroupBox("Default Brush") {
                    VStack(alignment: .leading, spacing: 12) {
                        HStack {
                            Text("Brush")
                                .font(.system(size: 11, weight: .medium))
                                .frame(width: 60, alignment: .leading)
                            Picker("", selection: $prefs.defaultBrushName) {
                                ForEach(BrushDescriptor.allDefaults, id: \.name) { brush in
                                    Text(brush.name).tag(brush.name)
                                }
                            }
                            .pickerStyle(.menu)
                            .labelsHidden()
                        }

                        HStack {
                            Text("Size")
                                .font(.system(size: 11, weight: .medium))
                                .frame(width: 60, alignment: .leading)
                            Slider(value: $prefs.defaultBrushSize, in: 1...200)
                            Text("\(Int(prefs.defaultBrushSize))px")
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundColor(.secondary)
                                .frame(width: 50, alignment: .trailing)
                        }
                    }
                    .padding(4)
                }

                Spacer()
            }
            .padding(20)
        }
        .onAppear {
            customWidth = "\(prefs.defaultCanvasWidth)"
            customHeight = "\(prefs.defaultCanvasHeight)"
        }
    }

    private func commitCustom() {
        if let w = Int(customWidth), let h = Int(customHeight),
           w >= 64, w <= 8192, h >= 64, h <= 8192 {
            prefs.defaultCanvasWidth = w
            prefs.defaultCanvasHeight = h
        }
    }
}
