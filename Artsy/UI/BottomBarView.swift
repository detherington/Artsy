import SwiftUI
import ArtsyEngine

/// What the chrome knows about the window it is in.
final class ChromeState: ObservableObject {
    /// Wide enough for the Layers dock beside the canvas.
    @Published var isWide = false
    /// Too narrow for the full bar: the quick controls as buttons with their values, the
    /// panel buttons without labels (an iPad in portrait, a phone).
    @Published var isCompact = false
    /// A phone: no rail, the tools in a strip over the canvas, finger-sized targets.
    @Published var isPhone = false
}

/// The bar along the bottom of the window: the document, then the four things a painter
/// changes every minute — brush, size, opacity, colour — as controls a pen can drag, then
/// Layers, Adjust, Add and the way to hide it all.
struct BottomBarView: View {
    @ObservedObject var viewModel: CanvasViewModel
    @ObservedObject var chrome: ChromeState
    let previews: BrushPreviewCache
    let actions: ChromeActions
    @State private var showingLayers = false
    @State private var showingAdjust = false
    @State private var showingAdd = false

    var body: some View {
        Group {
            if chrome.isCompact {
                compact
            } else {
                full
            }
        }
        .padding(.horizontal, chrome.isPhone ? 6 : 10)
        .frame(height: Chrome.barHeight)
        .frame(maxWidth: .infinity)
        .background(Chrome.background)
    }

    /// The compact bar: the same things, the quick values as buttons that open their
    /// pill, the panel buttons as icons alone.
    private var compact: some View {
        let target = chrome.isPhone ? Chrome.compactTarget : Chrome.target
        return HStack(spacing: chrome.isPhone ? 6 : 8) {
            DocumentMenu(viewModel: viewModel, actions: actions, compact: true)
            BrushPill(viewModel: viewModel, previews: previews, actions: actions, compact: true)
            ValueButton(title: "Size", value: $viewModel.brushSize, range: 1...200, logarithmic: true, size: target) { "\(Int($0.rounded()))" }
            ValueButton(title: "Opacity", value: $viewModel.brushOpacity, range: 0.05...1, logarithmic: false, size: target) { "\(Int(($0 * 100).rounded()))%" }
            ColorSwatchButton(viewModel: viewModel)
            Spacer(minLength: 4)
            ChromeButton(systemImage: "square.3.layers.3d", badge: viewModel.layerStack?.layers.count, size: target, help: "Layers") {
                showingLayers = true
            }
            .popover(isPresented: $showingLayers, arrowEdge: Chrome.barPopoverEdge) {
                LayersPanelView(viewModel: viewModel, renderer: actions.renderer(), dockAvailable: false)
                    .panelPresentation()
            }
            ChromeButton(systemImage: "slider.horizontal.3", size: target, help: "Symmetry, guides and the view") {
                showingAdjust = true
            }
            .popover(isPresented: $showingAdjust, arrowEdge: Chrome.barPopoverEdge) {
                AdjustPanelView(viewModel: viewModel, actions: actions)
                    .panelPresentation()
            }
            ChromeButton(systemImage: "plus", size: target, help: "AI, stock images and imports") {
                showingAdd = true
            }
            .popover(isPresented: $showingAdd, arrowEdge: Chrome.barPopoverEdge) {
                AddPanelView(viewModel: viewModel, actions: actions, dismiss: { showingAdd = false })
                    .panelPresentation()
            }
            ChromeButton(systemImage: "arrow.down.right.and.arrow.up.left", size: target, help: "Hide the interface") {
                viewModel.toggleChrome()
            }
        }
    }

    private var full: some View {
        HStack(spacing: 10) {
            DocumentMenu(viewModel: viewModel, actions: actions)
            Spacer(minLength: 8)
            BrushPill(viewModel: viewModel, previews: previews, actions: actions)
            ValuePill(title: "Size", value: $viewModel.brushSize, range: 1...200, logarithmic: true) { "\(Int($0.rounded()))" }
            ValuePill(title: "Opacity", value: $viewModel.brushOpacity, range: 0.05...1, logarithmic: false) { "\(Int(($0 * 100).rounded()))%" }
            ColorSwatchButton(viewModel: viewModel)
            Spacer(minLength: 8)
            ChromeButton(systemImage: "square.3.layers.3d", label: "Layers",
                         isSelected: chrome.isWide && viewModel.isLayersDocked,
                         badge: viewModel.layerStack?.layers.count, help: "Layers") {
                if chrome.isWide {
                    viewModel.isLayersDocked.toggle()
                } else {
                    showingLayers = true
                }
            }
            .popover(isPresented: $showingLayers, arrowEdge: Chrome.barPopoverEdge) {
                LayersPanelView(viewModel: viewModel, renderer: actions.renderer(), dockAvailable: chrome.isWide)
                    .panelPresentation()
            }
            ChromeButton(systemImage: "slider.horizontal.3", label: "Adjust", help: "Symmetry, guides and the view") {
                showingAdjust = true
            }
            .popover(isPresented: $showingAdjust, arrowEdge: Chrome.barPopoverEdge) {
                AdjustPanelView(viewModel: viewModel, actions: actions)
                    .panelPresentation()
            }
            ChromeButton(systemImage: "plus", label: "Add", help: "AI, stock images and imports") {
                showingAdd = true
            }
            .popover(isPresented: $showingAdd, arrowEdge: Chrome.barPopoverEdge) {
                AddPanelView(viewModel: viewModel, actions: actions, dismiss: { showingAdd = false })
                    .panelPresentation()
            }
            ChromeButton(systemImage: "arrow.down.right.and.arrow.up.left", label: "Hide", help: "Hide the interface (Tab)") {
                viewModel.toggleChrome()
            }
        }
    }
}

// MARK: - The document

struct DocumentMenu: View {
    @ObservedObject var viewModel: CanvasViewModel
    let actions: ChromeActions
    /// The icon alone, with a dot for unsaved changes.
    var compact = false

    var body: some View {
        Menu {
            #if os(macOS)
            Button("New Canvas…") { actions.app("showNewCanvasDialog") }
            Button("Open…") { actions.app("handleOpen") }
            Divider()
            Button("Save…") { actions.app("handleSave") }
            Button("Export PNG…") { actions.app("handleExportPNG") }
            Button("Export PNG (16-bit)…") { actions.app("handleExportPNG16") }
            Button("Export JPEG…") { actions.app("handleExportJPEG") }
            #else
            // The start screen is the screen behind this one; saving is continuous
            Button("Start") { actions.app("handleOpen") }
            Button("Save now") { actions.app("handleSave") }
            Divider()
            Button("Export PNG…") { actions.app("handleExportPNG") }
            Button("Export PNG (16-bit)…") { actions.app("handleExportPNG16") }
            Button("Export JPEG…") { actions.app("handleExportJPEG") }
            Divider()
            Button("Settings…") { actions.app("showSettings") }
            Button("Keyboard Shortcuts…") { actions.app("showShortcuts") }
            #endif
            Divider()
            TimelapseMenu(actions: actions)
            Divider()
            Text("\(Int(viewModel.canvasSize.width)) × \(Int(viewModel.canvasSize.height)) px, "
                 + ByteCountFormatter.string(fromByteCount: Int64(viewModel.memoryUseBytes), countStyle: .memory) + " in use")
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "line.3.horizontal")
                    .font(.system(size: 16))
                if compact {
                    if viewModel.isDirty { Text("•").font(Chrome.font) }
                } else {
                    Text((viewModel.isDirty ? "• " : "") + viewModel.displayName)
                        .font(Chrome.font)
                        .lineLimit(1)
                }
            }
            .foregroundColor(Chrome.text)
            .padding(.horizontal, compact ? 6 : 10)
            .frame(height: 36)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("File")
    }
}

/// The Time-lapse submenu: the canvas's own recording switch, Replay, Export at full
/// length or 30 seconds, Delete, and the recording's length and size.
struct TimelapseMenu: View {
    let actions: ChromeActions

    var body: some View {
        if let recorder = actions.renderer()?.timelapse {
            TimelapseRecorderMenu(recorder: recorder, actions: actions)
        } else {
            Menu("Time-lapse") {
                Toggle("Record Time-lapse", isOn: Binding(get: { false }, set: { _ in actions.app("timelapseToggleRecording") }))
                Divider()
                Text("Nothing recorded yet")
            }
        }
    }
}

/// The submenu of a canvas with a recorder, following it as it records.
struct TimelapseRecorderMenu: View {
    @ObservedObject var recorder: TimelapseRecorder
    let actions: ChromeActions

    var body: some View {
        let hasFrames = recorder.frames > 0
        Menu("Time-lapse") {
            Toggle("Record Time-lapse", isOn: Binding(get: { recorder.isRecording },
                                                      set: { _ in actions.app("timelapseToggleRecording") }))
            Divider()
            Button("Replay…") { actions.app("timelapseReplay") }
                .disabled(!hasFrames)
            Button("Export Full Length…") { actions.app("timelapseExportFull") }
                .disabled(!hasFrames)
            Button("Export 30 Seconds…") { actions.app("timelapseExportShort") }
                .disabled(!hasFrames)
            Divider()
            Button("Delete Time-lapse…", role: .destructive) { actions.app("timelapseDelete") }
                .disabled(!hasFrames)
            Divider()
            Text(recorder.summary)
        }
    }
}

// MARK: - The quick controls

/// The current brush, with its stroke; tap for the brush panel.
struct BrushPill: View {
    @ObservedObject var viewModel: CanvasViewModel
    let previews: BrushPreviewCache
    let actions: ChromeActions
    /// The stroke and the chevron, without the name.
    var compact = false
    @State private var showing = false

    var body: some View {
        Button(action: { showing = true }) {
            HStack(spacing: 8) {
                if let image = previews.image(for: viewModel.currentBrush) {
                    Image(platformImage: image)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(width: 54, height: 18)
                }
                if !compact {
                    Text(viewModel.currentBrush.name)
                        .font(Chrome.font)
                        .foregroundColor(Chrome.text)
                        .lineLimit(1)
                }
                Image(systemName: "chevron.up")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundColor(Chrome.secondaryText)
            }
            .padding(.horizontal, compact ? 8 : 12)
            .frame(height: 36)
            .background(Capsule().fill(Chrome.control))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .help("Brush")
        .popover(isPresented: $showing, arrowEdge: Chrome.barPopoverEdge) {
            BrushPanelView(viewModel: viewModel, previews: previews, actions: actions, dismiss: { showing = false })
                .panelPresentation()
        }
    }
}

/// A value on the compact bar: its number with its name under it, and a tap for the pill
/// that drags it, in a popover that stays one on a phone.
struct ValueButton: View {
    let title: String
    @Binding var value: Float
    let range: ClosedRange<Float>
    let logarithmic: Bool
    var size: CGFloat = Chrome.target
    let format: (Float) -> String
    @State private var showing = false

    var body: some View {
        Button(action: { showing = true }) {
            VStack(spacing: 1) {
                Text(format(value))
                    .font(Chrome.valueFont)
                    .foregroundColor(Chrome.text)
                Text(title)
                    .font(.system(size: 9))
                    .foregroundColor(Chrome.secondaryText)
            }
            .frame(width: size, height: size)
            .background(RoundedRectangle(cornerRadius: 10).fill(Chrome.control))
            .contentShape(RoundedRectangle(cornerRadius: 10))
        }
        .buttonStyle(.plain)
        .help(title)
        .popover(isPresented: $showing, arrowEdge: Chrome.barPopoverEdge) {
            ValuePill(title: title, value: $value, range: range, logarithmic: logarithmic, format: format)
                .padding(12)
                .background(Chrome.panel)
                .popoverStaysPopover()
        }
    }
}

/// A value a pen drags: the pill shows the value and a thumb, and a drag anywhere on it
/// moves the value — the full track's width from one end of the range to the other.
struct ValuePill: View {
    let title: String
    @Binding var value: Float
    let range: ClosedRange<Float>
    /// Spread the low end out (brush sizes: 1 to 10 matter as much as 100 to 200).
    let logarithmic: Bool
    let format: (Float) -> String
    @State private var dragStart: CGFloat?

    static let trackWidth: CGFloat = 70
    private static let thumb: CGFloat = 16

    var body: some View {
        HStack(spacing: 8) {
            Text(title)
                .font(Chrome.labelFont)
                .foregroundColor(Chrome.secondaryText)
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Chrome.hairline)
                    .frame(height: 4)
                Circle()
                    .fill(Chrome.text)
                    .frame(width: Self.thumb, height: Self.thumb)
                    .offset(x: position * (Self.trackWidth - Self.thumb))
            }
            .frame(width: Self.trackWidth, height: 20)
            Text(format(value))
                .font(Chrome.valueFont)
                .foregroundColor(Chrome.text)
                .frame(width: 38, alignment: .trailing)
        }
        .padding(.horizontal, 12)
        .frame(height: 36)
        .background(Capsule().fill(Chrome.control))
        .contentShape(Capsule())
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { drag in
                    let start = dragStart ?? position
                    dragStart = start
                    let t = start + drag.translation.width / (Self.trackWidth - Self.thumb)
                    value = Self.value(at: t, in: range, logarithmic: logarithmic)
                }
                .onEnded { _ in dragStart = nil }
        )
        .help("\(title): drag to change")
    }

    private var position: CGFloat { Self.position(of: value, in: range, logarithmic: logarithmic) }

    /// Where on the track (0 to 1) a value sits.
    static func position(of value: Float, in range: ClosedRange<Float>, logarithmic: Bool) -> CGFloat {
        let v = min(range.upperBound, max(range.lowerBound, value))
        if logarithmic {
            return CGFloat((log(v) - log(range.lowerBound)) / (log(range.upperBound) - log(range.lowerBound)))
        }
        return CGFloat((v - range.lowerBound) / (range.upperBound - range.lowerBound))
    }

    /// The value at a point on the track (0 to 1, clamped).
    static func value(at position: CGFloat, in range: ClosedRange<Float>, logarithmic: Bool) -> Float {
        let t = Float(min(1, max(0, position)))
        let value = logarithmic
            ? exp(log(range.lowerBound) + t * (log(range.upperBound) - log(range.lowerBound)))
            : range.lowerBound + t * (range.upperBound - range.lowerBound)
        return min(range.upperBound, max(range.lowerBound, value))
    }
}

/// The foreground colour over the background colour; a tap on either opens its picker.
struct ColorSwatchButton: View {
    @ObservedObject var viewModel: CanvasViewModel
    @State private var showingForeground = false
    @State private var showingBackground = false

    var body: some View {
        ZStack(alignment: .topLeading) {
            Button(action: { showingBackground = true }) {
                RoundedRectangle(cornerRadius: 7)
                    .fill(viewModel.swapBackgroundColor.displayColor)
                    .frame(width: 36, height: 36)
                    .overlay(RoundedRectangle(cornerRadius: 7).stroke(Color.white.opacity(0.25), lineWidth: 1))
            }
            .buttonStyle(.plain)
            .help("Background colour")
            .popover(isPresented: $showingBackground, arrowEdge: Chrome.barPopoverEdge) {
                ColorPanelView(
                    color: Binding(get: { viewModel.swapBackgroundColor }, set: { viewModel.swapBackgroundColor = $0 }),
                    viewModel: viewModel, dismiss: { showingBackground = false }
                )
                .panelPresentation()
            }
            Button(action: { showingForeground = true }) {
                RoundedRectangle(cornerRadius: 5)
                    .fill(viewModel.foregroundColor.displayColor)
                    .frame(width: 24, height: 24)
                    .overlay(RoundedRectangle(cornerRadius: 5).stroke(Color.white.opacity(0.6), lineWidth: 1))
            }
            .buttonStyle(.plain)
            .help("Colour (X swaps the two)")
            .popover(isPresented: $showingForeground, arrowEdge: Chrome.barPopoverEdge) {
                ColorPanelView(
                    color: Binding(get: { viewModel.foregroundColor },
                                   set: { viewModel.foregroundColor = $0; viewModel.currentColor = $0 }),
                    viewModel: viewModel, dismiss: { showingForeground = false }
                )
                .panelPresentation()
            }
        }
        .frame(width: 36, height: 36)
    }
}

// MARK: - The panels

extension BrushCategory {
    var title: String {
        self == .utility ? "Erasers and tools" : rawValue.capitalized
    }
}

/// The brushes, by category, each with its stroke; the current brush's settings under
/// them, and the Studio for the rest.
/// Symmetry, the view, guides and the paper around the canvas.
struct AdjustPanelView: View {
    @ObservedObject var viewModel: CanvasViewModel
    let actions: ChromeActions

    private static let papers: [(name: String, grey: Double)] = [
        ("Dark", 0.10), ("Mid", 0.35), ("Light", 0.65), ("Black", 0), ("White", 1),
    ]
    private static let gridSpacings = [16, 32, 64, 128, 256]

    var body: some View {
        VStack(spacing: 0) {
            PanelHeader("Adjust")
            Divider().overlay(Chrome.hairline)
            DragScroll {
                VStack(spacing: 0) {
                    PanelSectionLabel("Symmetry")
                    SymmetryButtons(viewModel: viewModel)

                    PanelSectionLabel("Tilt")
                    TiltControl(viewModel: viewModel)

                    PanelSectionLabel("View")
                    PanelRow(systemImage: "arrow.counterclockwise.circle", label: "Reset view", note: "fit, upright", action: actions.resetView)
                    PanelRow(systemImage: "arrow.up.left.and.down.right.magnifyingglass", label: "Zoom to fit", note: "⌘0", action: actions.zoomToFit)
                    PanelRow(systemImage: "1.magnifyingglass", label: "Actual size", note: "⌘1", action: actions.actualSize)
                    PanelRow(systemImage: "rotate.left", label: "Rotate left", note: "⌥⌘[") { actions.rotate(1) }
                    PanelRow(systemImage: "rotate.right", label: "Rotate right", note: "⌥⌘]") { actions.rotate(-1) }
                    PanelRow(systemImage: "arrow.counterclockwise", label: "Reset rotation", note: "⌥⌘0", action: actions.resetRotation)
                    PanelRow(systemImage: "arrow.left.and.right.righttriangle.left.righttriangle.right", label: "Flip view", note: "⌥⌘F", action: actions.flip)

                    PanelSectionLabel("Guides")
                    PanelRow(systemImage: "grid", label: "Grid", note: viewModel.guides.showsGrid ? "On" : "Off",
                             isSelected: viewModel.guides.showsGrid) { actions.changeGuides { $0.showsGrid.toggle() } }
                    HStack(spacing: 6) {
                        Text("Spacing")
                            .font(Chrome.labelFont)
                            .foregroundColor(Chrome.secondaryText)
                            .frame(width: 60, alignment: .leading)
                        ForEach(Self.gridSpacings, id: \.self) { spacing in
                            let selected = Int(viewModel.guides.gridSpacing) == spacing
                            Button("\(spacing)") { actions.changeGuides { $0.gridSpacing = CGFloat(spacing) } }
                                .buttonStyle(.plain)
                                .font(Chrome.valueFont)
                                .foregroundColor(selected ? Chrome.text : Chrome.secondaryText)
                                .frame(width: 44, height: 36)
                                .background(RoundedRectangle(cornerRadius: 8).fill(selected ? Chrome.selected : Chrome.control))
                        }
                    }
                    .padding(.horizontal, 20)
                    .padding(.vertical, 4)
                    PanelRow(systemImage: "squareshape.split.3x3", label: "Snap to grid", note: viewModel.guides.snapsToGrid ? "On" : "Off",
                             isSelected: viewModel.guides.snapsToGrid) { actions.changeGuides { $0.snapsToGrid.toggle() } }
                    PanelRow(systemImage: "ruler", label: "Snap to guides", note: viewModel.guides.snapsToGuides ? "On" : "Off",
                             isSelected: viewModel.guides.snapsToGuides) { actions.changeGuides { $0.snapsToGuides.toggle() } }
                    PanelRow(systemImage: "minus", label: "Add horizontal guide") { actions.addGuide(true) }
                    PanelRow(systemImage: "poweron", label: "Add vertical guide") { actions.addGuide(false) }
                    PanelRow(systemImage: "xmark", label: "Clear guides", note: "\(viewModel.guides.horizontals.count + viewModel.guides.verticals.count)") {
                        actions.changeGuides { $0.horizontals.removeAll(); $0.verticals.removeAll() }
                    }

                    PanelSectionLabel("Paper around the canvas")
                    HStack(spacing: 10) {
                        ForEach(Self.papers, id: \.name) { paper in
                            let selected = abs(viewModel.canvasBackgroundColor.r - paper.grey) < 0.01
                            Button(action: { viewModel.canvasBackgroundColor = (paper.grey, paper.grey, paper.grey) }) {
                                RoundedRectangle(cornerRadius: 8)
                                    .fill(Color(white: paper.grey))
                                    .frame(width: 44, height: 36)
                                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(selected ? Color.accentColor : Chrome.hairline, lineWidth: selected ? 2 : 1))
                            }
                            .buttonStyle(.plain)
                            .help(paper.name)
                        }
                    }
                    .padding(.horizontal, 20)
                    .padding(.vertical, 6)
                    .padding(.bottom, 10)
                }
            }
        }
        .frame(width: Chrome.panelWidth, height: 640)
        .background(Chrome.panel)
    }
}

/// Symmetry as buttons a pen can hit: off, the mirrors, and radial by how many ways.
struct SymmetryButtons: View {
    @ObservedObject var viewModel: CanvasViewModel

    static let radialChoices = [3, 4, 6, 8, 12]

    var body: some View {
        VStack(spacing: 6) {
            HStack(spacing: 6) {
                mode("Off", systemImage: "nosign", .off)
                mode("Mirror", systemImage: "align.vertical.center.fill", .horizontal)
                mode("Up-down", systemImage: "align.horizontal.center.fill", .vertical)
                mode("Quad", systemImage: "square.grid.2x2.fill", .quad)
            }
            HStack(spacing: 6) {
                Text("Radial")
                    .font(Chrome.font)
                    .foregroundColor(Chrome.secondaryText)
                    .frame(width: 60, alignment: .leading)
                ForEach(Self.radialChoices, id: \.self) { n in
                    let selected = viewModel.symmetryMode == .radial(n)
                    Button(action: { viewModel.symmetryMode = .radial(n) }) {
                        Text("\(n)")
                            .font(Chrome.valueFont)
                            .frame(maxWidth: .infinity)
                            .frame(height: 40)
                            .background(RoundedRectangle(cornerRadius: 8).fill(selected ? Chrome.selected : Chrome.control))
                            .contentShape(RoundedRectangle(cornerRadius: 8))
                    }
                    .buttonStyle(.plain)
                    .foregroundColor(selected ? Chrome.text : Chrome.secondaryText)
                    .help("Strokes repeat \(n) ways around the centre")
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.bottom, 8)
    }

    static let modeHeight: CGFloat = 52

    private func mode(_ label: String, systemImage: String, _ mode: SymmetryMode) -> some View {
        let selected = viewModel.symmetryMode == mode
        return Button(action: { viewModel.symmetryMode = mode }) {
            VStack(spacing: 3) {
                Image(systemName: systemImage)
                    .font(.system(size: 18))
                Text(label)
                    .font(Chrome.labelFont)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity)
            .frame(height: Self.modeHeight)
            .background(RoundedRectangle(cornerRadius: 8).fill(selected ? Chrome.selected : Chrome.control))
            .contentShape(RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
        .foregroundColor(selected ? Chrome.text : Chrome.secondaryText)
        .help(mode == .off ? "No symmetry" : "Strokes mirror across the canvas")
    }
}

/// Things that put something on the canvas now and then: AI, stock images, imports.
struct AddPanelView: View {
    @ObservedObject var viewModel: CanvasViewModel
    let actions: ChromeActions
    let dismiss: () -> Void
    @StateObject private var aiManager = AIResultsManager()
    @StateObject private var unsplashManager = UnsplashManager()
    @State private var section = 0

    var body: some View {
        VStack(spacing: 0) {
            PanelHeader("Add")
            Picker("", selection: $section) {
                Text("AI generate").tag(0)
                Text("Stock images").tag(1)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(.horizontal, 14)
            .padding(.bottom, 10)
            Divider().overlay(Chrome.hairline)
            DragScroll {
                VStack(spacing: 0) {
                    if section == 0 {
                        AIPanelView(viewModel: viewModel, aiManager: aiManager, actions: actions)
                    } else {
                        UnsplashPanelView(manager: unsplashManager, viewModel: viewModel, actions: actions)
                    }
                    Divider().overlay(Chrome.hairline).padding(.vertical, 8)
                    PanelRow(systemImage: "photo.on.rectangle", label: "Import an image…", note: "as a layer") {
                        dismiss()
                        actions.app("handleImportImage")
                    }
                    PanelRow(systemImage: "paintbrush", label: "Import brushes…") {
                        dismiss()
                        actions.app("handleImportBrush")
                    }
                    PanelRow(systemImage: "photo", label: "Import a tip or grain image…") {
                        dismiss()
                        actions.app("handleImportTexture")
                    }
                }
                .padding(.vertical, 8)
            }
        }
        .frame(width: Chrome.panelWidth, height: 640)
        .background(Chrome.panel)
    }
}

// MARK: - Over the canvas

/// With the chrome hidden, the brush and the colour stay within reach in a corner, with
/// the way back.
struct ChromePillView: View {
    @ObservedObject var viewModel: CanvasViewModel
    let previews: BrushPreviewCache
    let actions: ChromeActions

    var body: some View {
        HStack(spacing: 8) {
            BrushPill(viewModel: viewModel, previews: previews, actions: actions)
            ColorSwatchButton(viewModel: viewModel)
            ChromeButton(systemImage: "arrow.up.left.and.arrow.down.right", help: "Show the interface (Tab)") {
                viewModel.toggleChrome()
            }
        }
        .padding(6)
        .background(RoundedRectangle(cornerRadius: 14).fill(Chrome.background.opacity(0.92)))
    }
}

/// The zoom, shown for a moment when it changes.
struct ZoomHUDView: View {
    @ObservedObject var viewModel: CanvasViewModel
    @State private var shownUntil = Date.distantPast
    @State private var visible = false

    var body: some View {
        Text("\(Int((viewModel.transform.scale * 100).rounded()))%")
            .font(Chrome.valueFont)
            .foregroundColor(Chrome.text)
            .padding(.horizontal, 12)
            .frame(height: 28)
            .background(Capsule().fill(Chrome.background.opacity(0.9)))
            .opacity(visible ? 1 : 0)
            .allowsHitTesting(false)
            .onChange(of: viewModel.transform.scale) { _, _ in
                visible = true
                let until = Date().addingTimeInterval(1.2)
                shownUntil = until
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
                    if shownUntil <= until {
                        withAnimation(.easeOut(duration: 0.25)) { visible = false }
                    }
                }
            }
    }
}
