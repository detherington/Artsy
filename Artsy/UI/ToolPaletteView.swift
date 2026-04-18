import SwiftUI
import AppKit

struct ToolPaletteView: View {
    @ObservedObject var viewModel: CanvasViewModel
    @State private var showForegroundPicker = false
    @State private var showBackgroundPicker = false

    var body: some View {
        VStack(spacing: 2) {
            // Tool buttons
            ForEach(ToolType.allCases) { tool in
                ToolButton(
                    tool: tool,
                    isSelected: viewModel.currentTool == tool,
                    action: { selectTool(tool) }
                )

                // Show selection mode sub-tools when selection is active
                if tool == .selection && viewModel.currentTool == .selection {
                    HStack(spacing: 1) {
                        ForEach(SelectionMode.allCases) { mode in
                            SelectionModeButton(
                                mode: mode,
                                isSelected: viewModel.selectionMode == mode,
                                action: { viewModel.selectionMode = mode }
                            )
                        }
                    }
                    .padding(.horizontal, 2)
                    .padding(.bottom, 2)
                }

                // Show shape mode sub-tools when shape tool is active
                if tool == .shape && viewModel.currentTool == .shape {
                    HStack(spacing: 1) {
                        ForEach(ShapeMode.allCases) { mode in
                            ShapeModeButton(
                                mode: mode,
                                isSelected: viewModel.currentShape == mode,
                                action: { viewModel.currentShape = mode }
                            )
                        }
                    }
                    .padding(.horizontal, 2)
                    .padding(.bottom, 2)
                }
            }

            Divider()
                .padding(.vertical, 4)

            // Color swatches
            ZStack {
                Rectangle()
                    .fill(Color(nsColor: viewModel.swapBackgroundColor.nsColor))
                    .frame(width: 20, height: 20)
                    .border(Color.white.opacity(0.4), width: 1)
                    .offset(x: 6, y: 6)
                    .onTapGesture { showBackgroundPicker = true }
                    .popover(isPresented: $showBackgroundPicker, arrowEdge: .trailing) {
                        CustomColorPickerView(
                            color: Binding(
                                get: { viewModel.swapBackgroundColor },
                                set: { viewModel.swapBackgroundColor = $0 }
                            ),
                            onCommit: { showBackgroundPicker = false }
                        )
                    }

                Rectangle()
                    .fill(Color(nsColor: viewModel.foregroundColor.nsColor))
                    .frame(width: 20, height: 20)
                    .border(Color.white.opacity(0.6), width: 1)
                    .offset(x: -4, y: -4)
                    .onTapGesture { showForegroundPicker = true }
                    .popover(isPresented: $showForegroundPicker, arrowEdge: .trailing) {
                        CustomColorPickerView(
                            color: Binding(
                                get: { viewModel.foregroundColor },
                                set: {
                                    viewModel.foregroundColor = $0
                                    viewModel.currentColor = $0
                                }
                            ),
                            onCommit: { showForegroundPicker = false }
                        )
                    }
            }
            .frame(width: 36, height: 36)

            Button("⇄") {
                viewModel.swapColors()
            }
            .font(.system(size: 11))
            .buttonStyle(.plain)
            .foregroundColor(.white)

            Divider()
                .padding(.vertical, 4)

            // Brush size preview + label
            VStack(spacing: 4) {
                let previewSize = CGFloat(max(4, min(28, viewModel.brushSize * 0.2)))
                Circle()
                    .fill(Color.white)
                    .frame(width: previewSize, height: previewSize)
                    .frame(width: 32, height: 32)

                Text("\(Int(viewModel.brushSize))")
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundColor(.gray)
            }
            .help("Brush size: \(Int(viewModel.brushSize))px  ([ / ] to adjust)")

            Spacer()

            // Brush presets
            ForEach(Array(BrushDescriptor.allDefaults.enumerated()), id: \.element.id) { index, brush in
                BrushPresetButton(
                    brush: brush,
                    isSelected: viewModel.currentBrush.id == brush.id,
                    index: index + 1,
                    action: {
                        viewModel.currentBrush = brush
                        viewModel.currentTool = .brush
                    }
                )
            }
        }
        .padding(.vertical, 8)
        .padding(.horizontal, 4)
        .frame(width: 48)
        .background(Color(nsColor: NSColor(white: 0.15, alpha: 1.0)))
    }

    private func selectTool(_ tool: ToolType) {
        viewModel.currentTool = tool
        switch tool {
        case .brush:
            if viewModel.currentBrush.id == BrushDescriptor.eraser.id {
                viewModel.currentBrush = .hardRound
            }
        case .eraser:
            viewModel.currentBrush = .eraser
        default:
            break
        }
    }
}

struct ToolButton: View {
    let tool: ToolType
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: tool.iconName)
                .font(.system(size: 16))
                .frame(width: 32, height: 32)
                .background(isSelected ? Color.accentColor.opacity(0.3) : Color.clear)
                .cornerRadius(4)
        }
        .buttonStyle(.plain)
        .foregroundColor(isSelected ? .accentColor : .gray)
        .help("\(tool.rawValue) (\(tool.shortcutKey))")
    }
}

struct SelectionModeButton: View {
    let mode: SelectionMode
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: mode.iconName)
                .font(.system(size: 10))
                .frame(width: 14, height: 14)
                .background(isSelected ? Color.accentColor.opacity(0.3) : Color(white: 0.25))
                .cornerRadius(2)
        }
        .buttonStyle(.plain)
        .foregroundColor(isSelected ? .white : .gray)
        .help(mode.rawValue)
    }
}

struct ShapeModeButton: View {
    let mode: ShapeMode
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: mode.iconName)
                .font(.system(size: 10))
                .frame(width: 14, height: 14)
                .background(isSelected ? Color.accentColor.opacity(0.3) : Color(white: 0.25))
                .cornerRadius(2)
        }
        .buttonStyle(.plain)
        .foregroundColor(isSelected ? .white : .gray)
        .help(mode.rawValue)
    }
}

struct BrushPresetButton: View {
    let brush: BrushDescriptor
    let isSelected: Bool
    let index: Int
    let action: () -> Void

    private var iconName: String {
        switch brush.name {
        case "Hard Round": return "pencil.tip"
        case "Soft Round": return "circle.fill"
        case "Pencil": return "pencil"
        case "Ink Brush": return "paintbrush.pointed.fill"
        case "Marker": return "highlighter"
        case "Watercolor": return "drop.fill"
        case "Acrylic": return "paintbrush.fill"
        default: return "circle.fill"
        }
    }

    var body: some View {
        Button(action: action) {
            VStack(spacing: 1) {
                Image(systemName: iconName)
                    .font(.system(size: 14))
                Text("\(index)")
                    .font(.system(size: 8, design: .monospaced))
            }
            .frame(width: 36, height: 34)
            .background(isSelected ? Color.accentColor.opacity(0.3) : Color.clear)
            .cornerRadius(4)
        }
        .buttonStyle(.plain)
        .foregroundColor(isSelected ? .white : .gray)
        .help("\(brush.name) (\(index))")
    }
}

// MARK: - StrokeColor SwiftUI extension

extension StrokeColor {
    var swiftUIColor: Color {
        Color(red: Double(red), green: Double(green), blue: Double(blue), opacity: Double(alpha))
    }

    var nsColor: NSColor {
        // Create as Display P3 since the pipeline stores and renders in P3
        NSColor(displayP3Red: CGFloat(red), green: CGFloat(green), blue: CGFloat(blue), alpha: CGFloat(alpha))
    }
}

extension Color {
    var strokeColor: StrokeColor {
        // Read the raw CGColor components — no color space conversion, so the
        // values the user typed in the color picker are what gets stored.
        let cg = NSColor(self).cgColor
        let components = cg.components ?? []
        let r = components.count > 0 ? Float(components[0]) : 0
        let g = components.count > 1 ? Float(components[1]) : 0
        let b = components.count > 2 ? Float(components[2]) : 0
        let a = cg.alpha
        return StrokeColor(red: r, green: g, blue: b, alpha: Float(a))
    }
}

extension NSColor {
    /// Convert an NSColor (from NSColorPanel) into a StrokeColor in Display P3.
    var strokeColor: StrokeColor {
        let p3 = self.usingColorSpace(.displayP3) ?? self
        return StrokeColor(
            red: Float(p3.redComponent),
            green: Float(p3.greenComponent),
            blue: Float(p3.blueComponent),
            alpha: Float(p3.alphaComponent)
        )
    }
}
