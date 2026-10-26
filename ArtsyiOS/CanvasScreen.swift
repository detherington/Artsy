import SwiftUI
import ArtsyEngine

/// The canvas with the bar along the bottom: the brush, its size and opacity, the colour,
/// undo and redo, and a graphite brush's grade. The first slice; the Mac's panels follow.
struct CanvasScreen: View {
    @ObservedObject var session: PaintingSession

    var body: some View {
        ZStack(alignment: .bottom) {
            if let context = session.context, let renderer = session.renderer {
                // The canvas runs under the bars; the bar below keeps clear of the home indicator
                CanvasHost(context: context, viewModel: session.viewModel, renderer: renderer)
                    .ignoresSafeArea()
            } else {
                Color(white: 0.13).ignoresSafeArea()
                Text(session.failure ?? "The engine could not start")
                    .foregroundColor(.white)
                    .padding()
            }
            BottomBar(session: session)
        }
        .background(Color(white: 0.13))
    }
}

/// The chrome's few constants, as on the Mac: dark, one accent, pen-sized targets.
enum Chrome {
    static let barHeight: CGFloat = 52
    static let target: CGFloat = 44
    static let background = Color(white: 0.13)
    static let panel = Color(white: 0.16)
    static let control = Color(white: 0.22)
    static let selected = Color.accentColor.opacity(0.35)
    static let text = Color(white: 0.92)
    static let secondaryText = Color(white: 0.62)
    static let font = Font.system(size: 13)
    static let valueFont = Font.system(size: 12, design: .monospaced)
}

struct BottomBar: View {
    @ObservedObject var session: PaintingSession
    @ObservedObject var viewModel: CanvasViewModel

    init(session: PaintingSession) {
        self.session = session
        self.viewModel = session.viewModel
    }

    var body: some View {
        VStack(spacing: 0) {
            if viewModel.currentBrush.graphite {
                GradeRow(viewModel: viewModel)
            }
            HStack(spacing: 12) {
                BrushMenu(viewModel: viewModel)
                LogSlider(label: "Size", value: $viewModel.brushSize, range: 1...200) { "\(Int($0.rounded()))" }
                LogSlider(label: "Opacity", value: $viewModel.brushOpacity, range: 0.05...1, logarithmic: false) { "\(Int(($0 * 100).rounded()))%" }
                ColorPicker("", selection: Binding(
                    get: { Color(red: Double(viewModel.currentColor.red), green: Double(viewModel.currentColor.green), blue: Double(viewModel.currentColor.blue)) },
                    set: { color in
                        let resolved = color.resolve(in: EnvironmentValues())
                        viewModel.currentColor = StrokeColor(red: resolved.red, green: resolved.green, blue: resolved.blue, alpha: 1)
                    }
                ), supportsOpacity: false)
                .labelsHidden()
                .frame(width: Chrome.target, height: Chrome.target)
                Button(action: { if let renderer = session.renderer { viewModel.performUndo(renderer: renderer) } }) {
                    Image(systemName: "arrow.uturn.backward").font(.system(size: 18))
                        .frame(width: Chrome.target, height: Chrome.target)
                }
                .disabled(!viewModel.undoManager.canUndo)
                Button(action: { if let renderer = session.renderer { viewModel.performRedo(renderer: renderer) } }) {
                    Image(systemName: "arrow.uturn.forward").font(.system(size: 18))
                        .frame(width: Chrome.target, height: Chrome.target)
                }
                .disabled(!viewModel.undoManager.canRedo)
            }
            .padding(.horizontal, 12)
            .frame(height: Chrome.barHeight)
        }
        .padding(.bottom, 4)
        .background(Chrome.background.opacity(0.96))
        .foregroundColor(Chrome.text)
    }
}

/// The brush, as a menu of the library by category; the current one is the label.
struct BrushMenu: View {
    @ObservedObject var viewModel: CanvasViewModel

    var body: some View {
        Menu {
            ForEach(BrushCategory.allCases.filter { $0 != .utility }, id: \.self) { category in
                Section(category.rawValue.capitalized) {
                    ForEach(BrushLibrary.shared.all.filter { $0.category == category }) { brush in
                        Button(action: { viewModel.currentBrush = brush; viewModel.currentTool = .brush }) {
                            Label(brush.name, systemImage: brush.id == viewModel.currentBrush.id ? "checkmark" : "paintbrush.pointed")
                        }
                    }
                }
            }
            Section("Erasers") {
                Button(action: { viewModel.currentBrush = .eraser; viewModel.currentTool = .eraser }) {
                    Label("Eraser", systemImage: viewModel.currentTool == .eraser ? "checkmark" : "eraser")
                }
            }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "paintbrush.pointed").font(.system(size: 15))
                Text(viewModel.currentBrush.name).font(Chrome.font).lineLimit(1)
            }
            .padding(.horizontal, 12)
            .frame(height: Chrome.target)
            .background(Capsule().fill(Chrome.control))
        }
        .foregroundColor(Chrome.text)
    }
}

/// A labelled slider: the label, the track, the value.
struct LogSlider: View {
    let label: String
    @Binding var value: Float
    let range: ClosedRange<Float>
    var logarithmic = true
    let format: (Float) -> String

    private var position: Binding<Double> {
        Binding(
            get: {
                let v = min(max(value, range.lowerBound), range.upperBound)
                return logarithmic ? Double(log(v / range.lowerBound) / log(range.upperBound / range.lowerBound))
                                   : Double((v - range.lowerBound) / (range.upperBound - range.lowerBound))
            },
            set: { t in
                let t = Float(min(max(t, 0), 1))
                value = logarithmic ? range.lowerBound * pow(range.upperBound / range.lowerBound, t)
                                    : range.lowerBound + (range.upperBound - range.lowerBound) * t
            }
        )
    }

    var body: some View {
        HStack(spacing: 8) {
            Text(label).font(Chrome.font).foregroundColor(Chrome.secondaryText)
            Slider(value: position, in: 0...1)
            Text(format(value)).font(Chrome.valueFont).foregroundColor(Chrome.text).frame(width: 44, alignment: .trailing)
        }
    }
}

/// A graphite brush's grade, 2H to 6B, as pills.
struct GradeRow: View {
    @ObservedObject var viewModel: CanvasViewModel

    var body: some View {
        HStack(spacing: 6) {
            Text("Grade").font(Chrome.font).foregroundColor(Chrome.secondaryText)
            ForEach(PencilGrade.shown) { grade in
                let selected = viewModel.pencilGrade == grade
                Button(action: { viewModel.pencilGrade = grade }) {
                    Text(grade.rawValue)
                        .font(Chrome.valueFont)
                        .frame(maxWidth: .infinity)
                        .frame(height: 36)
                        .background(RoundedRectangle(cornerRadius: 8).fill(selected ? Chrome.selected : Chrome.control))
                }
                .foregroundColor(selected ? Chrome.text : Chrome.secondaryText)
            }
        }
        .padding(.horizontal, 12)
        .frame(height: Chrome.target)
    }
}
