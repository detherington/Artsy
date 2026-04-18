import SwiftUI

struct BrushSettingsView: View {
    @ObservedObject var viewModel: CanvasViewModel

    var body: some View {
        Group {
            if viewModel.currentTool == .shape {
                ShapeSettingsContent(viewModel: viewModel)
            } else {
                BrushSettingsContent(viewModel: viewModel)
            }
        }
    }
}

struct BrushSettingsContent: View {
    @ObservedObject var viewModel: CanvasViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Brush: \(viewModel.currentBrush.name)")
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(.white)

            HStack {
                Text("Size")
                    .font(.system(size: 10))
                    .foregroundColor(.gray)
                    .frame(width: 52, alignment: .leading)
                Slider(value: $viewModel.brushSize, in: 1...200)
                Text("\(Int(viewModel.brushSize))")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundColor(.gray)
                    .frame(width: 28, alignment: .trailing)
            }

            HStack {
                Text("Opacity")
                    .font(.system(size: 10))
                    .foregroundColor(.gray)
                    .frame(width: 52, alignment: .leading)
                Slider(value: $viewModel.brushOpacity, in: 0.05...1.0)
                Text("\(Int(viewModel.brushOpacity * 100))%")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundColor(.gray)
                    .frame(width: 28, alignment: .trailing)
            }

            // Pressure curve preset picker
            HStack {
                Text("Pressure")
                    .font(.system(size: 10))
                    .foregroundColor(.gray)
                    .frame(width: 52, alignment: .leading)

                Picker("", selection: Binding(
                    get: { pressureCurveLabel(viewModel.pressureCurve) },
                    set: { viewModel.pressureCurve = pressureCurveForLabel($0) }
                )) {
                    Text("Linear").tag("Linear")
                    Text("Soft").tag("Soft")
                    Text("Firm").tag("Firm")
                }
                .pickerStyle(.segmented)
            }

            Divider().padding(.vertical, 2)

            // Smoothing
            HStack {
                Text("Smooth")
                    .font(.system(size: 10))
                    .foregroundColor(.gray)
                    .frame(width: 52, alignment: .leading)

                Picker("", selection: $viewModel.smoothingMode) {
                    ForEach(SmoothingMode.allCases) { mode in
                        Text(mode.rawValue).tag(mode)
                    }
                }
                .pickerStyle(.menu)
            }

            if viewModel.smoothingMode != .none {
                HStack {
                    Text("Amount")
                        .font(.system(size: 10))
                        .foregroundColor(.gray)
                        .frame(width: 52, alignment: .leading)
                    Slider(value: $viewModel.smoothingStrength, in: 0.0...1.0)
                    Text("\(Int(viewModel.smoothingStrength * 100))%")
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundColor(.gray)
                        .frame(width: 28, alignment: .trailing)
                }
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 4)
    }

    private func pressureCurveLabel(_ curve: PressureCurve) -> String {
        if curve == .linear { return "Linear" }
        if curve == .soft { return "Soft" }
        if curve == .firm { return "Firm" }
        return "Linear"
    }

    private func pressureCurveForLabel(_ label: String) -> PressureCurve {
        switch label {
        case "Soft": return .soft
        case "Firm": return .firm
        default: return .linear
        }
    }
}

struct ShapeSettingsContent: View {
    @ObservedObject var viewModel: CanvasViewModel
    @State private var showStrokePicker = false
    @State private var showFillPicker = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Shape: \(viewModel.currentShape.rawValue)")
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(.white)

            // Stroke toggle + color
            HStack {
                Toggle(isOn: $viewModel.shapeStrokeEnabled) {
                    Text("Stroke")
                        .font(.system(size: 11))
                        .foregroundColor(.gray)
                }
                .toggleStyle(.checkbox)
                Spacer()
                Rectangle()
                    .fill(Color(nsColor: viewModel.foregroundColor.nsColor))
                    .frame(width: 16, height: 16)
                    .border(Color.white.opacity(0.4), width: 1)
                    .contentShape(Rectangle())
                    .onTapGesture { showStrokePicker = true }
                    .popover(isPresented: $showStrokePicker, arrowEdge: .trailing) {
                        CustomColorPickerView(
                            color: Binding(
                                get: { viewModel.foregroundColor },
                                set: {
                                    viewModel.foregroundColor = $0
                                    viewModel.currentColor = $0
                                }
                            ),
                            onCommit: { showStrokePicker = false }
                        )
                    }
            }

            if viewModel.shapeStrokeEnabled {
                HStack {
                    Text("Width")
                        .font(.system(size: 10))
                        .foregroundColor(.gray)
                        .frame(width: 52, alignment: .leading)
                    Slider(value: $viewModel.shapeStrokeWidth, in: 1...40)
                    Text("\(Int(viewModel.shapeStrokeWidth))")
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundColor(.gray)
                        .frame(width: 28, alignment: .trailing)
                }
            }

            Divider().padding(.vertical, 2)

            // Fill toggle + color
            HStack {
                Toggle(isOn: $viewModel.shapeFillEnabled) {
                    Text("Fill")
                        .font(.system(size: 11))
                        .foregroundColor(.gray)
                }
                .toggleStyle(.checkbox)
                Spacer()
                Rectangle()
                    .fill(Color(nsColor: viewModel.swapBackgroundColor.nsColor))
                    .frame(width: 16, height: 16)
                    .border(Color.white.opacity(0.4), width: 1)
                    .contentShape(Rectangle())
                    .onTapGesture {
                        viewModel.shapeFillEnabled = true
                        showFillPicker = true
                    }
                    .popover(isPresented: $showFillPicker, arrowEdge: .trailing) {
                        CustomColorPickerView(
                            color: Binding(
                                get: { viewModel.swapBackgroundColor },
                                set: { viewModel.swapBackgroundColor = $0 }
                            ),
                            onCommit: { showFillPicker = false }
                        )
                    }
            }

            Text("Stroke uses foreground color, fill uses background color.")
                .font(.system(size: 9))
                .foregroundColor(.gray.opacity(0.7))
                .lineLimit(2)
        }
        .padding(.horizontal, 16).padding(.vertical, 4)
    }
}
