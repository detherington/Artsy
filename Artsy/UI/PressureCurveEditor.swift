import SwiftUI

/// Maps the pen's pressure to the pressure the brush sees: a cubic Bézier with two handles
/// to drag. Flattening the start makes a light touch count for more; steepening the end
/// keeps full pressure for a firm press.
struct PressureCurveEditor: View {
    @Binding var curve: PressureCurve
    var size: CGFloat = 140

    private var handle1: CGPoint { curve.controlPoint1.cgPoint }
    private var handle2: CGPoint { curve.controlPoint2.cgPoint }

    var body: some View {
        ZStack {
            Canvas { context, _ in
                // Grid
                var grid = Path()
                for i in 1..<4 {
                    let t = CGFloat(i) / 4 * size
                    grid.move(to: CGPoint(x: t, y: 0)); grid.addLine(to: CGPoint(x: t, y: size))
                    grid.move(to: CGPoint(x: 0, y: t)); grid.addLine(to: CGPoint(x: size, y: t))
                }
                context.stroke(grid, with: .color(.secondary.opacity(0.25)), lineWidth: 0.5)
                // The straight line, for reference
                var diagonal = Path()
                diagonal.move(to: view(CGPoint(x: 0, y: 0)))
                diagonal.addLine(to: view(CGPoint(x: 1, y: 1)))
                context.stroke(diagonal, with: .color(.secondary.opacity(0.35)), style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
                // Handle stems
                var stems = Path()
                stems.move(to: view(CGPoint(x: 0, y: 0))); stems.addLine(to: view(handle1))
                stems.move(to: view(CGPoint(x: 1, y: 1))); stems.addLine(to: view(handle2))
                context.stroke(stems, with: .color(.accentColor.opacity(0.5)), lineWidth: 1)
                // The curve as the brush sees it
                var path = Path()
                for i in 0...48 {
                    let x = Float(i) / 48
                    let point = view(CGPoint(x: CGFloat(x), y: CGFloat(curve.map(x))))
                    if i == 0 { path.move(to: point) } else { path.addLine(to: point) }
                }
                context.stroke(path, with: .color(.accentColor), lineWidth: 2)
            }

            handle(at: handle1) { curve = PressureCurve(controlPoint1: $0, controlPoint2: handle2) }
            handle(at: handle2) { curve = PressureCurve(controlPoint1: handle1, controlPoint2: $0) }
        }
        .frame(width: size, height: size)
        .background(Color(nsColor: .controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.secondary.opacity(0.3)))
    }

    /// Curve space (0...1, y up) to view space.
    private func view(_ point: CGPoint) -> CGPoint {
        CGPoint(x: point.x * size, y: (1 - point.y) * size)
    }

    private func handle(at point: CGPoint, move: @escaping (CGPoint) -> Void) -> some View {
        Circle()
            .fill(Color.accentColor)
            .frame(width: 12, height: 12)
            .overlay(Circle().stroke(Color.white, lineWidth: 1.5))
            .position(view(point))
            .gesture(DragGesture(minimumDistance: 0).onChanged { value in
                move(CGPoint(x: min(1, max(0, value.location.x / size)),
                             y: min(1, max(0, 1 - value.location.y / size))))
            })
    }
}

/// The pressure control for the brush settings panel: a thumbnail of the curve that opens
/// the editor and the presets, with a note on which pen the curve belongs to.
struct PressureCurveControl: View {
    @ObservedObject var viewModel: CanvasViewModel
    @State private var isEditing = false

    private static let presets: [(String, PressureCurve)] = [("Linear", .linear), ("Soft", .soft), ("Firm", .firm)]

    var body: some View {
        Button(action: { isEditing = true }) {
            HStack(spacing: 6) {
                PressureCurveThumbnail(curve: viewModel.pressureCurve)
                    .frame(width: 22, height: 22)
                Text(presetName ?? "Custom")
                    .font(.system(size: 10))
                    .foregroundColor(.gray)
            }
        }
        .buttonStyle(.plain)
        .popover(isPresented: $isEditing, arrowEdge: .trailing) {
            VStack(alignment: .leading, spacing: 10) {
                Text("Pressure")
                    .font(.system(size: 12, weight: .semibold))
                PressureCurveEditor(curve: curveBinding)
                HStack {
                    ForEach(Self.presets, id: \.0) { name, preset in
                        Button(name) { curveBinding.wrappedValue = preset }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                    }
                }
                Text(TabletEventHandler.currentPenID == nil
                     ? "Used until a pen is detected; each pen then keeps its own curve."
                     : "Saved for the pen in use.")
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
                    .frame(width: 140)
            }
            .padding(12)
        }
    }

    private var presetName: String? {
        Self.presets.first { $0.1 == viewModel.pressureCurve }?.0
    }

    /// Edits go to the canvas and are saved for the current pen.
    private var curveBinding: Binding<PressureCurve> {
        Binding(
            get: { viewModel.pressureCurve },
            set: { curve in
                viewModel.pressureCurve = curve
                AppPreferences.shared.pressureCurves[TabletEventHandler.currentPenKey] = curve
            }
        )
    }
}

struct PressureCurveThumbnail: View {
    let curve: PressureCurve

    var body: some View {
        Canvas { context, size in
            var path = Path()
            for i in 0...16 {
                let x = Float(i) / 16
                let point = CGPoint(x: CGFloat(x) * size.width, y: (1 - CGFloat(curve.map(x))) * size.height)
                if i == 0 { path.move(to: point) } else { path.addLine(to: point) }
            }
            context.stroke(path, with: .color(.white.opacity(0.85)), lineWidth: 1.5)
        }
        .background(Color.white.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 3))
    }
}
