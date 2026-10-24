import AppKit
import SwiftUI

/// The brush panel: a strip of categories over a grid of brush cards, each a stroke
/// preview with the name under it, and the current brush's own settings beneath. A long
/// press on a card (or a right-click) offers duplicate, reset, export and delete.
struct BrushPanelView: View {
    @ObservedObject var viewModel: CanvasViewModel
    @ObservedObject private var library = BrushLibrary.shared
    let previews: BrushPreviewCache
    let actions: ChromeActions
    let dismiss: () -> Void
    @State private var category: BrushPanelCategory
    @State private var deleting: BrushDescriptor?

    init(viewModel: CanvasViewModel, previews: BrushPreviewCache, actions: ChromeActions, dismiss: @escaping () -> Void) {
        self.viewModel = viewModel
        self.previews = previews
        self.actions = actions
        self.dismiss = dismiss
        _category = State(initialValue: BrushPanelCategory.holding(viewModel.currentBrush, in: BrushLibrary.shared))
    }

    static let columns = 2
    static let cardSpacing: CGFloat = 10
    static let gridInset: CGFloat = 12

    private struct Entry: Identifiable {
        let brush: BrushDescriptor
        /// Position in the library: the number keys pick the first nine.
        let index: Int
        var id: UUID { brush.id }
    }

    private var entries: [Entry] {
        // The eraser is a brush like the rest here, though the library keeps it apart
        let all = library.all + (library.all.contains { $0.id == BrushDescriptor.eraser.id } ? [] : [.eraser])
        return all.enumerated()
            .map { Entry(brush: $0.element, index: $0.offset) }
            .filter { category.holds($0.brush, in: library) }
    }

    var body: some View {
        VStack(spacing: 0) {
            PanelHeader("Brushes") {
                Button("Studio…") {
                    dismiss()
                    actions.app("showBrushStudio")
                }
                .buttonStyle(.plain)
                .font(Chrome.font)
                .foregroundColor(Chrome.text)
                .padding(.horizontal, 12)
                .frame(height: 32)
                .background(Capsule().fill(Chrome.control))
                .help("Every setting of this brush")
            }
            Divider().overlay(Chrome.hairline)
            BrushCategoryStrip(selected: $category)
            Divider().overlay(Chrome.hairline)
            DragScroll {
                VStack(spacing: 0) {
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: Self.cardSpacing), count: Self.columns),
                              spacing: Self.cardSpacing) {
                        ForEach(entries) { entry in
                            BrushCard(
                                brush: entry.brush,
                                image: previews.image(for: entry.brush),
                                number: entry.index < 9 ? entry.index + 1 : nil,
                                isSelected: viewModel.currentBrush.id == entry.brush.id,
                                isUserBrush: library.isUserBrush(entry.brush)
                            ) {
                                BrushPanelActions.select(entry.brush, viewModel: viewModel)
                            } menu: { action in
                                perform(action, on: entry.brush)
                            }
                        }
                    }
                    .padding(Self.gridInset)
                    if entries.isEmpty {
                        Text(category == .mine ? "Duplicate a brush, or import one under Add, and it appears here."
                                               : "No brushes here.")
                            .font(Chrome.font)
                            .foregroundColor(Chrome.secondaryText)
                            .multilineTextAlignment(.center)
                            .padding(20)
                    }
                    Divider().overlay(Chrome.hairline)
                    BrushQuickSettings(viewModel: viewModel, actions: actions, dismiss: dismiss)
                        .padding(.bottom, 12)
                }
            }
        }
        .frame(width: Chrome.panelWidth, height: 600)
        .background(Chrome.panel)
        .confirmationDialog("Delete \"\(deleting?.name ?? "")\"?", isPresented: Binding(
            get: { deleting != nil }, set: { if !$0 { deleting = nil } }
        ), titleVisibility: .visible) {
            Button("Delete", role: .destructive) {
                if let brush = deleting { BrushPanelActions.delete(brush, in: library, viewModel: viewModel) }
                deleting = nil
            }
            Button("Cancel", role: .cancel) { deleting = nil }
        } message: {
            Text("The brush file goes with it. Built-in brushes cannot be deleted.")
        }
    }

    private func perform(_ action: BrushCardAction, on brush: BrushDescriptor) {
        switch action {
        case .duplicate:
            if BrushPanelActions.duplicate(brush, in: library, viewModel: viewModel) != nil { category = .mine }
        case .reset:
            BrushPanelActions.reset(brush, viewModel: viewModel)
        case .export:
            BrushPanelActions.select(brush, viewModel: viewModel)
            dismiss()
            actions.app("handleExportBrush")
        case .delete:
            deleting = brush
        }
    }
}

/// The strip's categories: the brush's own, and "Mine" for the user's duplicates and imports.
enum BrushPanelCategory: CaseIterable, Equatable {
    case sketching, inking, painting, erasers, mine

    var title: String {
        switch self {
        case .sketching: return "Sketching"
        case .inking: return "Inking"
        case .painting: return "Painting"
        case .erasers: return "Erasers"
        case .mine: return "Mine"
        }
    }

    func holds(_ brush: BrushDescriptor, in library: BrushLibrary) -> Bool {
        if library.isUserBrush(brush) { return self == .mine }
        switch self {
        case .sketching: return brush.category == .sketching
        case .inking: return brush.category == .inking
        case .painting: return brush.category == .painting
        case .erasers: return brush.category == .utility
        case .mine: return false
        }
    }

    /// The category a brush is found under.
    static func holding(_ brush: BrushDescriptor, in library: BrushLibrary) -> BrushPanelCategory {
        allCases.first { $0.holds(brush, in: library) } ?? .inking
    }
}

struct BrushCategoryStrip: View {
    @Binding var selected: BrushPanelCategory

    var body: some View {
        HStack(spacing: 4) {
            ForEach(BrushPanelCategory.allCases, id: \.self) { category in
                Button(action: { selected = category }) {
                    Text(category.title)
                        .font(Chrome.labelFont)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                        .frame(maxWidth: .infinity)
                        .frame(height: 40)
                        .background(RoundedRectangle(cornerRadius: 8).fill(selected == category ? Chrome.selected : Chrome.control))
                        .contentShape(RoundedRectangle(cornerRadius: 8))
                }
                .buttonStyle(.plain)
                .foregroundColor(selected == category ? Chrome.text : Chrome.secondaryText)
                .help(category.title)
            }
        }
        .padding(.horizontal, BrushPanelView.gridInset)
        .padding(.vertical, 8)
    }
}

enum BrushCardAction {
    case duplicate, reset, export, delete
}

/// A brush in the grid: its stroke, its name, its number key if it has one; the current
/// brush marked. A right-click, which a pen gets by holding still, opens the menu.
struct BrushCard: View {
    let brush: BrushDescriptor
    let image: NSImage?
    let number: Int?
    let isSelected: Bool
    let isUserBrush: Bool
    let select: () -> Void
    let menu: (BrushCardAction) -> Void

    static let height: CGFloat = 78

    var body: some View {
        Button(action: select) {
            VStack(spacing: 4) {
                ZStack(alignment: .topTrailing) {
                    Group {
                        if let image {
                            Image(nsImage: image)
                                .resizable()
                                .aspectRatio(contentMode: .fit)
                        } else {
                            Image(brush.iconAssetName)
                                .renderingMode(.template)
                                .resizable()
                                .aspectRatio(contentMode: .fit)
                                .frame(width: 24, height: 24)
                        }
                    }
                    .frame(maxWidth: .infinity)
                    .frame(height: 44)
                    if let number {
                        Text("\(number)")
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundColor(Chrome.secondaryText)
                            .padding(.horizontal, 5)
                            .frame(minWidth: 16, minHeight: 16)
                            .background(Capsule().fill(Chrome.control))
                    }
                }
                Text(brush.name)
                    .font(Chrome.font)
                    .foregroundColor(isSelected ? Chrome.text : Chrome.secondaryText)
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity)
            .frame(height: Self.height)
            .background(RoundedRectangle(cornerRadius: 10).fill(isSelected ? Chrome.selected : Chrome.control.opacity(0.6)))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(isSelected ? Color.accentColor : Color.clear, lineWidth: 1.5))
            .contentShape(RoundedRectangle(cornerRadius: 10))
        }
        .buttonStyle(.plain)
        .help(number.map { "\(brush.name) (\($0))" } ?? brush.name)
        .contextMenu {
            Button("Duplicate") { menu(.duplicate) }
            Button("Reset Size and Smoothing") { menu(.reset) }
            Button("Export…") { menu(.export) }
            if isUserBrush {
                Divider()
                Button("Delete…") { menu(.delete) }
            }
        }
    }
}

/// What the cards' menu does, apart from the views, so it can be tested without them.
enum BrushPanelActions {
    static func select(_ brush: BrushDescriptor, viewModel: CanvasViewModel) {
        viewModel.currentBrush = brush
        viewModel.currentTool = brush.id == BrushDescriptor.eraser.id ? .eraser : .brush
    }

    /// A copy of the brush among the user's, selected. Nil if the library could not save it.
    @discardableResult
    static func duplicate(_ brush: BrushDescriptor, in library: BrushLibrary, viewModel: CanvasViewModel) -> BrushDescriptor? {
        guard let copy = try? library.duplicate(brush) else { return nil }
        select(copy, viewModel: viewModel)
        return copy
    }

    /// The brush's size and smoothing back to its own, forgetting what the painter set.
    static func reset(_ brush: BrushDescriptor, viewModel: CanvasViewModel) {
        if viewModel.currentBrush.id != brush.id { select(brush, viewModel: viewModel) }
        viewModel.brushSize = brush.baseSize
        viewModel.smoothingStrength = brush.smoothing
    }

    /// A user's brush gone; if it was the current brush, Hard Round takes its place.
    static func delete(_ brush: BrushDescriptor, in library: BrushLibrary, viewModel: CanvasViewModel) {
        guard library.isUserBrush(brush) else { return }
        try? library.remove(brush)
        if viewModel.currentBrush.id == brush.id { select(.hardRound, viewModel: viewModel) }
    }
}

/// The current brush's own settings, under the grid: the four a painter reaches for, and
/// the way to the Studio for the rest.
struct BrushQuickSettings: View {
    @ObservedObject var viewModel: CanvasViewModel
    let actions: ChromeActions
    let dismiss: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            PanelSectionLabel(viewModel.currentBrush.name)
            PanelSlider("Size", value: $viewModel.brushSize, range: 1...200, logarithmic: true) { "\(Int($0.rounded()))" }
            PanelSlider("Opacity", value: $viewModel.brushOpacity, range: 0.05...1) { "\(Int(($0 * 100).rounded()))%" }
            HStack(spacing: 12) {
                Text("Pressure")
                    .font(Chrome.font)
                    .foregroundColor(Chrome.secondaryText)
                    .frame(width: 64, alignment: .leading)
                PressureCurveControl(viewModel: viewModel)
                Spacer()
            }
            .padding(.horizontal, 14)
            .frame(height: Chrome.target)
            HStack(spacing: 12) {
                Text("Smooth")
                    .font(Chrome.font)
                    .foregroundColor(Chrome.secondaryText)
                    .frame(width: 64, alignment: .leading)
                Picker("", selection: Binding(
                    get: { viewModel.smoothingMode },
                    set: {
                        viewModel.smoothingMode = $0
                        // Remembered across launches; the amount below belongs to the brush
                        AppPreferences.shared.smoothingMode = $0
                    }
                )) {
                    ForEach(SmoothingMode.allCases) { mode in
                        Text(mode.rawValue).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            }
            .padding(.horizontal, 14)
            .frame(height: Chrome.target)
            if viewModel.smoothingMode != .none {
                PanelSlider("Amount", value: $viewModel.smoothingStrength, range: 0...1) { "\(Int(($0 * 100).rounded()))%" }
            }
            PanelRow(systemImage: "slider.horizontal.3", label: "Everything else", note: "Studio") {
                dismiss()
                actions.app("showBrushStudio")
            }
        }
    }
}

/// A labelled slider in a panel, a pen-sized row: the label, the track, the value.
struct PanelSlider: View {
    let label: String
    @Binding var value: Float
    let range: ClosedRange<Float>
    var logarithmic = false
    let format: (Float) -> String

    init(_ label: String, value: Binding<Float>, range: ClosedRange<Float>, logarithmic: Bool = false,
         format: @escaping (Float) -> String) {
        self.label = label
        self._value = value
        self.range = range
        self.logarithmic = logarithmic
        self.format = format
    }

    /// The slider's own value runs 0...1 along the track; logarithmic tracks give the small
    /// end of the range the room it needs.
    private var position: Binding<Double> {
        Binding(
            get: {
                let v = min(max(value, range.lowerBound), range.upperBound)
                if logarithmic {
                    return Double(log(v / range.lowerBound) / log(range.upperBound / range.lowerBound))
                }
                return Double((v - range.lowerBound) / (range.upperBound - range.lowerBound))
            },
            set: { t in
                let t = Float(min(max(t, 0), 1))
                value = logarithmic
                    ? range.lowerBound * pow(range.upperBound / range.lowerBound, t)
                    : range.lowerBound + (range.upperBound - range.lowerBound) * t
            }
        )
    }

    var body: some View {
        HStack(spacing: 12) {
            Text(label)
                .font(Chrome.font)
                .foregroundColor(Chrome.secondaryText)
                .frame(width: 64, alignment: .leading)
            Slider(value: position, in: 0...1)
                .controlSize(.large)
            Text(format(value))
                .font(Chrome.valueFont)
                .foregroundColor(Chrome.text)
                .frame(width: 44, alignment: .trailing)
        }
        .padding(.horizontal, 14)
        .frame(height: Chrome.target)
    }
}

extension BrushDescriptor {
    /// The icon in the asset catalogue for a built-in brush; a round tip for the rest.
    var iconAssetName: String {
        switch name {
        case "Hard Round": return "brush-hard-round"
        case "Soft Round": return "brush-soft-round"
        case "Pencil": return "brush-pencil"
        case "Graphite Stick": return "brush-graphite"
        case "Conté": return "brush-conte"
        case "Chalk": return "brush-chalk"
        case "Pastel": return "brush-pastel"
        case "Ink Brush": return "brush-ink-brush"
        case "Sumi-e": return "brush-sumi-e"
        case "Calligraphy": return "brush-calligraphy"
        case "Technical Pen": return "brush-technical-pen"
        case "Fineliner": return "brush-fineliner"
        case "Ballpoint": return "brush-ballpoint"
        case "Gel Pen": return "brush-gel-pen"
        case "Marker": return "brush-marker"
        case "Airbrush": return "brush-airbrush"
        case "Watercolor": return "brush-watercolor"
        case "Acrylic": return "brush-acrylic"
        case "Oil": return "brush-oil"
        default: return "brush-hard-round"
        }
    }
}
