import SwiftUI

struct AIPanelView: View {
    @ObservedObject var viewModel: CanvasViewModel
    @ObservedObject var aiManager: AIResultsManager
    @StateObject private var customStyles = CustomStyleStore()

    @State private var prompt: String = ""
    @State private var selectedBuiltinStyle: AIStyle? = .photorealistic
    @State private var selectedCustomStyle: CustomStylePreset? = nil
    @State private var selectedQuality: AIQuality = .medium
    @State private var showSavePreset = false
    @State private var newPresetName: String = ""
    @State private var editingPreset: CustomStylePreset? = nil
    @State private var previewResult: AIGeneratedImage? = nil

    // Whether the prompt overrides or supplements the style
    @State private var promptMode: PromptMode = .supplement

    enum PromptMode: String, CaseIterable {
        case supplement = "Add to style"
        case override_ = "Custom only"
    }

    private var effectiveStyle: AIStyle? {
        if promptMode == .override_ { return .custom }
        return selectedBuiltinStyle
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            // Service toggle
            Picker("", selection: Binding(
                get: { aiManager.configuration.preferredService },
                set: { aiManager.configuration.preferredService = $0 }
            )) {
                ForEach(AIConfiguration.AIServiceType.allCases) { service in
                    Text(service.rawValue).tag(service)
                }
            }
            .pickerStyle(.segmented)

            // Built-in styles
            SectionLabel("Style")

            StylePresetGrid(
                selectedStyle: $selectedBuiltinStyle,
                onSelect: { selectedCustomStyle = nil }
            )

            // Custom presets
            if !customStyles.presets.isEmpty {
                SectionLabel("Custom Styles")

                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 6) {
                    ForEach(customStyles.presets) { preset in
                        CustomPresetButton(
                            preset: preset,
                            isSelected: selectedCustomStyle?.id == preset.id,
                            onSelect: {
                                selectedCustomStyle = preset
                                selectedBuiltinStyle = nil
                                prompt = preset.prompt
                                promptMode = .override_
                            },
                            onEdit: { editingPreset = preset },
                            onDelete: { customStyles.delete(preset) }
                        )
                    }
                }
            }

            Divider().padding(.vertical, 2)

            // Prompt mode
            Picker("", selection: $promptMode) {
                Text("Add to style").tag(PromptMode.supplement)
                Text("Custom only").tag(PromptMode.override_)
            }
            .pickerStyle(.segmented)
            .onChange(of: promptMode) { _, newValue in
                if newValue == .override_ {
                    selectedBuiltinStyle = nil
                } else if selectedBuiltinStyle == nil && selectedCustomStyle == nil {
                    selectedBuiltinStyle = .photorealistic
                }
            }

            // Prompt field
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    SectionLabel(promptMode == .supplement ? "Additional Prompt" : "Style Prompt")
                    Spacer()
                    if !prompt.isEmpty {
                        Button("Save preset") {
                            newPresetName = ""
                            showSavePreset = true
                        }
                        .font(.system(size: 10))
                        .buttonStyle(.plain)
                        .foregroundColor(.accentColor)
                    }
                }
                TextEditor(text: $prompt)
                    .font(.system(size: 11))
                    .frame(height: 60)
                    .scrollContentBackground(.hidden)
                    .padding(6)
                    .background(RoundedRectangle(cornerRadius: 5).fill(Color(white: 0.18)))
                    .overlay(RoundedRectangle(cornerRadius: 5).stroke(Color(white: 0.3), lineWidth: 0.5))
            }

            // Quality
            HStack {
                Text("Quality")
                    .font(.system(size: 11))
                    .foregroundColor(Color(white: 0.75))
                Spacer()
                Picker("", selection: $selectedQuality) {
                    ForEach(AIQuality.allCases) { q in
                        Text(q.displayName).tag(q)
                    }
                }
                .pickerStyle(.menu)
                .frame(width: 130)
            }

            // Generate
            if aiManager.isGenerating {
                HStack(spacing: 8) {
                    ProgressView()
                        .controlSize(.small)
                    Text(aiManager.progress ?? "Generating...")
                        .font(.system(size: 11))
                        .foregroundColor(.gray)
                    Spacer()
                    Button("Cancel") { aiManager.cancel() }
                        .controlSize(.small)
                }
                .padding(.vertical, 4)
            } else {
                Button(action: generate) {
                    Label("Generate from Canvas", systemImage: "sparkles")
                        .frame(maxWidth: .infinity)
                }
                .controlSize(.large)
                .disabled(!aiManager.activeService.isConfigured)

                if !aiManager.activeService.isConfigured {
                    Label("Set API key in Settings", systemImage: "exclamationmark.triangle.fill")
                        .font(.system(size: 10))
                        .foregroundColor(.orange)
                }
            }

            // Error
            if let error = aiManager.error {
                Text(error)
                    .font(.system(size: 10))
                    .foregroundColor(.red)
                    .lineLimit(3)
                    .padding(8)
                    .background(RoundedRectangle(cornerRadius: 5).fill(Color.red.opacity(0.1)))
            }

            // Results
            if !aiManager.results.isEmpty {
                Divider().padding(.vertical, 2)
                SectionLabel("Results")

                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 6) {
                    ForEach(aiManager.results.prefix(8)) { result in
                        AIResultThumbnail(result: result,
                            onTap: { previewResult = result },
                            onImport: { importResult(result) }
                        )
                    }
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 4)
        .sheet(isPresented: $showSavePreset) {
            SavePresetSheet(
                name: $newPresetName,
                prompt: prompt,
                onSave: {
                    customStyles.add(name: newPresetName, prompt: prompt)
                    showSavePreset = false
                },
                onCancel: { showSavePreset = false }
            )
        }
        .sheet(item: $previewResult) { result in
            VStack(spacing: 12) {
                if let nsImage = NSImage(data: result.imageData) {
                    Image(nsImage: nsImage)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(maxWidth: 600, maxHeight: 600)
                }
                HStack {
                    Button("Close") { previewResult = nil }
                        .keyboardShortcut(.cancelAction)
                    Spacer()
                    Button("Import as Layer") {
                        importResult(result)
                        previewResult = nil
                    }
                    .keyboardShortcut(.defaultAction)
                }
            }
            .padding(16)
            .frame(minWidth: 400, minHeight: 400)
        }
        .sheet(item: $editingPreset) { preset in
            EditPresetSheet(
                preset: preset,
                onSave: { updated in
                    customStyles.update(updated)
                    if selectedCustomStyle?.id == updated.id {
                        selectedCustomStyle = updated
                        prompt = updated.prompt
                    }
                    editingPreset = nil
                },
                onCancel: { editingPreset = nil }
            )
        }
    }

    private func generate() {
        // Get the canvas view's renderer to export the canvas image
        guard let appDelegate = NSApp.delegate as? AppDelegate,
              let store = appDelegate.activeStorePublic else {
            // Fallback to text-only generation
            Task {
                await aiManager.generateFromPrompt(
                    prompt: prompt,
                    style: effectiveStyle,
                    quality: selectedQuality,
                    size: .square
                )
            }
            return
        }

        // Export canvas as PNG data
        if let imageData = ImageExporter.exportForAI(renderer: store.canvasView.renderer) {
            Task {
                await aiManager.transformSketch(
                    imageData: imageData,
                    prompt: prompt,
                    style: effectiveStyle,
                    quality: selectedQuality
                )
            }
        } else {
            // Canvas export failed, try text-only
            Task {
                await aiManager.generateFromPrompt(
                    prompt: prompt,
                    style: effectiveStyle,
                    quality: selectedQuality,
                    size: .square
                )
            }
        }
    }

    private func importResult(_ result: AIGeneratedImage) {
        guard let appDelegate = NSApp.delegate as? AppDelegate,
              let store = appDelegate.activeStorePublic,
              let layerStack = store.viewModel.layerStack,
              let nsImage = NSImage(data: result.imageData),
              let cgImage = nsImage.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return }

        do {
            let idx = try layerStack.addLayer(above: layerStack.activeLayerIndex, name: "AI: \(result.model)")
            let layer = layerStack.layers[idx]

            // Load the image into the layer texture
            let renderer = store.canvasView.renderer!
            CanvasDocument.loadCGImageIntoTexture(
                cgImage: cgImage,
                texture: layer.texture,
                context: renderer.context
            )
        } catch {
            // Layer limit reached or other error
        }
    }
}

// MARK: - Style Preset Grid

struct StylePresetGrid: View {
    @Binding var selectedStyle: AIStyle?
    var onSelect: () -> Void = {}

    let styles = AIStyle.allCases.filter { $0 != .custom }

    private func iconName(for style: AIStyle) -> String {
        switch style {
        case .photorealistic: return "camera"
        case .oilPainting: return "paintbrush.fill"
        case .watercolor: return "drop.fill"
        case .digitalArt: return "desktopcomputer"
        case .anime: return "star.bubble.fill"
        case .pencilSketch: return "pencil"
        case .comicBook: return "book.fill"
        case .pixelArt: return "squareshape.split.3x3"
        case .impressionist: return "scribble"
        case .minimalist: return "circle"
        case .sciFiConcept: return "sparkle"
        case .fantasy: return "wand.and.stars"
        case .architecturalRender: return "building.2"
        case .custom: return "questionmark"
        }
    }

    private func shortName(for style: AIStyle) -> String {
        switch style {
        case .photorealistic: return "Photo"
        case .oilPainting: return "Oil"
        case .watercolor: return "Watercolor"
        case .digitalArt: return "Digital"
        case .anime: return "Anime"
        case .pencilSketch: return "Pencil"
        case .comicBook: return "Comic"
        case .pixelArt: return "Pixel"
        case .impressionist: return "Impress."
        case .minimalist: return "Minimal"
        case .sciFiConcept: return "Sci-Fi"
        case .fantasy: return "Fantasy"
        case .architecturalRender: return "Arch."
        case .custom: return "Custom"
        }
    }

    var body: some View {
        LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 6) {
            ForEach(styles) { style in
                Button(action: {
                    selectedStyle = style
                    onSelect()
                }) {
                    VStack(spacing: 4) {
                        Image(systemName: iconName(for: style))
                            .font(.system(size: 14))
                        Text(shortName(for: style))
                            .font(.system(size: 10, weight: .medium))
                            .lineLimit(1)
                    }
                    .frame(maxWidth: .infinity, minHeight: 44)
                    .background(
                        RoundedRectangle(cornerRadius: 6)
                            .fill(selectedStyle == style ? Color.accentColor.opacity(0.25) : Color(white: 0.2))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 6)
                            .stroke(selectedStyle == style ? Color.accentColor : Color.clear, lineWidth: 1)
                    )
                }
                .buttonStyle(.plain)
                .foregroundColor(selectedStyle == style ? .white : Color(white: 0.8))
                .help(style.rawValue)
            }
        }
    }
}

// MARK: - Custom Preset Button

struct CustomPresetButton: View {
    let preset: CustomStylePreset
    let isSelected: Bool
    let onSelect: () -> Void
    let onEdit: () -> Void
    let onDelete: () -> Void

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: "star.fill")
                .font(.system(size: 9))
                .foregroundColor(isSelected ? .white : Color(white: 0.55))
            Text(preset.name)
                .font(.system(size: 10, weight: .medium))
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, minHeight: 32)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(isSelected ? Color.accentColor.opacity(0.25) : Color(white: 0.2))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .stroke(isSelected ? Color.accentColor : Color.clear, lineWidth: 1)
        )
        .foregroundColor(isSelected ? .white : Color(white: 0.8))
        .contentShape(Rectangle())
        .onTapGesture { onSelect() }
        .contextMenu {
            Button("Edit") { onEdit() }
            Button("Delete", role: .destructive) { onDelete() }
        }
    }
}

// MARK: - Save Preset Sheet

struct SavePresetSheet: View {
    @Binding var name: String
    let prompt: String
    let onSave: () -> Void
    let onCancel: () -> Void

    var body: some View {
        VStack(spacing: 12) {
            Text("Save Custom Style")
                .font(.headline)

            TextField("Preset name", text: $name)
                .textFieldStyle(.roundedBorder)

            Text(prompt)
                .font(.system(size: 11))
                .foregroundColor(.secondary)
                .lineLimit(4)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(8)
                .background(Color(white: 0.95))
                .cornerRadius(4)

            HStack {
                Button("Cancel", action: onCancel)
                Spacer()
                Button("Save", action: onSave)
                    .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
                    .keyboardShortcut(.return)
            }
        }
        .padding(20)
        .frame(width: 320)
    }
}

// MARK: - Edit Preset Sheet

struct EditPresetSheet: View {
    let preset: CustomStylePreset
    let onSave: (CustomStylePreset) -> Void
    let onCancel: () -> Void

    @State private var name: String = ""
    @State private var prompt: String = ""

    var body: some View {
        VStack(spacing: 12) {
            Text("Edit Custom Style")
                .font(.headline)

            TextField("Preset name", text: $name)
                .textFieldStyle(.roundedBorder)

            TextEditor(text: $prompt)
                .font(.system(size: 11))
                .frame(height: 100)
                .cornerRadius(4)

            HStack {
                Button("Cancel", action: onCancel)
                Spacer()
                Button("Save") {
                    var updated = preset
                    updated.name = name
                    updated.prompt = prompt
                    onSave(updated)
                }
                .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
                .keyboardShortcut(.return)
            }
        }
        .padding(20)
        .frame(width: 360)
        .onAppear {
            name = preset.name
            prompt = preset.prompt
        }
    }
}

// MARK: - Result Thumbnail

// MARK: - Shared Section Label

struct SectionLabel: View {
    let text: String

    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text)
            .font(.system(size: 10, weight: .semibold))
            .foregroundColor(Color(white: 0.6))
            .textCase(.uppercase)
            .tracking(0.4)
    }
}

struct AIResultThumbnail: View {
    let result: AIGeneratedImage
    let onTap: () -> Void
    let onImport: () -> Void

    var body: some View {
        VStack(spacing: 2) {
            if let nsImage = NSImage(data: result.imageData) {
                Image(nsImage: nsImage)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .cornerRadius(4)
                    .onTapGesture { onTap() }
                    .help("Click to preview")
            }
            Button("Import", action: onImport)
                .controlSize(.mini)
        }
    }
}
