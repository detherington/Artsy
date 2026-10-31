import SwiftUI
import simd
import ArtsyEngine

// The chrome's two Mac-only pieces, as iPad and iPhone have them. The Mac needs a scroll
// view that scrolls under a pen drag; iOS scrolls under a finger and the Pencil alike, so
// a panel's list is a plain scroll view. The tilt pad is a SwiftUI drawing with a drag.

/// SwiftUI content a pen can scroll. Takes the width it is given; its height is the
/// content's, up to what it is given.
struct DragScroll<Content: View>: View {
    let content: Content
    /// Unused here: a drag anywhere on iOS is the content's when the content takes it.
    var dragHandleWidth: CGFloat = 0

    init(dragHandleWidth: CGFloat = 0, @ViewBuilder content: () -> Content) {
        self.dragHandleWidth = dragHandleWidth
        self.content = content()
    }

    var body: some View {
        ScrollView(.vertical, showsIndicators: false) {
            content
        }
    }
}

/// The paper's lean as a pad, bound to the lean: the dot is where the paper leans to, the
/// centre is level, and a touch near it snaps to level.
struct TiltPad: View {
    @Binding var tilt: SIMD2<Float>

    var body: some View {
        GeometryReader { geometry in
            let bounds = CGRect(origin: .zero, size: geometry.size)
            let inset = TiltPadMetrics.inset
            let reach = bounds.width / 2 - inset
            let dot = CGPoint(x: bounds.midX + CGFloat(tilt.x) * reach, y: bounds.midY + CGFloat(tilt.y) * reach)
            ZStack {
                Rectangle().fill(Chrome.control)
                Path { path in
                    path.move(to: CGPoint(x: bounds.midX, y: inset))
                    path.addLine(to: CGPoint(x: bounds.midX, y: bounds.maxY - inset))
                    path.move(to: CGPoint(x: inset, y: bounds.midY))
                    path.addLine(to: CGPoint(x: bounds.maxX - inset, y: bounds.midY))
                    path.addEllipse(in: CGRect(x: bounds.midX - reach, y: bounds.midY - reach, width: reach * 2, height: reach * 2))
                }
                .stroke(Chrome.hairline, lineWidth: 1)
                Circle()
                    .fill(tilt == .zero ? Chrome.secondaryText : Chrome.accent)
                    .frame(width: 14, height: 14)
                    .position(dot)
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        let lean = TiltPadMetrics.lean(at: value.location, in: bounds)
                        if lean != tilt { tilt = lean }
                    }
            )
        }
    }
}
