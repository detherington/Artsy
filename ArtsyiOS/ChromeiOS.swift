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

// MARK: - Square popovers

/// A popover from a control, as the chrome draws it: a square panel without an arrow or
/// a shadow, beside the control it opened from, dismissed by a tap outside. The view sits
/// behind the control as the anchor; the content is hosted in a controller of its own and
/// presented by UIKit through `SquarePanelPresentation`, so nothing of the system's
/// popover frame is drawn. On a phone the panel becomes a sheet, square-cornered with the
/// grabber, unless it is told to stay a popover.
struct SquarePopover<Content: View>: UIViewRepresentable {
    @Binding var isPresented: Bool
    /// Which way the popover lies from the control.
    let direction: UIPopoverArrowDirection
    /// Air between the control and the popover.
    let gap: CGFloat
    let staysPopover: Bool
    let content: () -> Content

    func makeUIView(context: Context) -> UIView {
        let anchor = UIView()
        anchor.backgroundColor = .clear
        anchor.isUserInteractionEnabled = false
        return anchor
    }

    func updateUIView(_ anchor: UIView, context: Context) {
        context.coordinator.parent = self
        context.coordinator.update(from: anchor)
    }

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    final class Coordinator: NSObject, UIViewControllerTransitioningDelegate, UIAdaptivePresentationControllerDelegate {
        var parent: SquarePopover
        private var hosting: UIHostingController<AnyView>?
        private weak var anchor: UIView?

        init(parent: SquarePopover) { self.parent = parent }

        private var framed: AnyView {
            AnyView(parent.content().overlay(Rectangle().strokeBorder(Chrome.hairline, lineWidth: 1)))
        }

        func update(from anchor: UIView) {
            self.anchor = anchor
            if parent.isPresented {
                if let hosting {
                    hosting.rootView = framed
                } else {
                    present(from: anchor)
                }
            } else if let hosting {
                self.hosting = nil
                hosting.dismiss(animated: true)
            }
        }

        private func present(from anchor: UIView) {
            let host = UIHostingController(rootView: framed)
            host.sizingOptions = .preferredContentSize
            host.view.backgroundColor = UIColor(Chrome.panel)
            host.overrideUserInterfaceStyle = Chrome.interfaceStyle
            if parent.staysPopover || anchor.traitCollection.horizontalSizeClass != .compact {
                host.modalPresentationStyle = .custom
                host.transitioningDelegate = self
            } else {
                host.modalPresentationStyle = .pageSheet
                host.presentationController?.delegate = self
                if let sheet = host.sheetPresentationController {
                    sheet.prefersGrabberVisible = true
                    sheet.preferredCornerRadius = 0
                }
            }
            hosting = host
            // Presented after the update that asked for it, not inside it
            DispatchQueue.main.async { [weak self] in
                guard let self, self.hosting === host, self.parent.isPresented else { return }
                var presenter = anchor.window?.rootViewController
                while let next = presenter?.presentedViewController { presenter = next }
                presenter?.present(host, animated: true)
            }
        }

        /// The panel went by a tap outside it or a pull down: the control's state follows.
        private func dismissed() {
            hosting = nil
            parent.isPresented = false
        }

        // MARK: UIViewControllerTransitioningDelegate

        func presentationController(forPresented presented: UIViewController, presenting: UIViewController?, source: UIViewController) -> UIPresentationController? {
            guard let anchor else { return nil }
            let presentation = SquarePanelPresentation(presentedViewController: presented, presenting: presenting,
                                                       anchor: anchor, direction: parent.direction, gap: parent.gap)
            presentation.onTapOutside = { [weak self, weak presented] in
                self?.dismissed()
                presented?.dismiss(animated: true)
            }
            return presentation
        }

        func animationController(forPresented presented: UIViewController, presenting: UIViewController, source: UIViewController) -> UIViewControllerAnimatedTransitioning? {
            SquarePanelTransition(presenting: true)
        }

        func animationController(forDismissed dismissed: UIViewController) -> UIViewControllerAnimatedTransitioning? {
            SquarePanelTransition(presenting: false)
        }

        // MARK: UIAdaptivePresentationControllerDelegate

        func presentationControllerDidDismiss(_ presentationController: UIPresentationController) {
            dismissed()
        }
    }
}

/// Where a square panel goes: beside the control it opened from, the way `direction`
/// says, at its preferred size or what fits between the control and the screen's edge,
/// and never past the safe area. A clear backdrop under it takes the tap that closes it.
final class SquarePanelPresentation: UIPresentationController {
    private let anchor: UIView
    private let direction: UIPopoverArrowDirection
    private let gap: CGFloat
    var onTapOutside: () -> Void = {}
    private let backdrop = UIView()

    init(presentedViewController: UIViewController, presenting: UIViewController?, anchor: UIView, direction: UIPopoverArrowDirection, gap: CGFloat) {
        self.anchor = anchor
        self.direction = direction
        self.gap = gap
        super.init(presentedViewController: presentedViewController, presenting: presenting)
    }

    override var frameOfPresentedViewInContainerView: CGRect {
        guard let container = containerView else { return .zero }
        let margin: CGFloat = 8
        let room = container.bounds.inset(by: container.safeAreaInsets).insetBy(dx: margin, dy: margin)
        let source = anchor.convert(anchor.bounds, to: container).insetBy(dx: -gap, dy: -gap)
        let wanted = presentedViewController.preferredContentSize
        var size = CGSize(width: wanted.width > 0 ? wanted.width : Chrome.panelWidth, height: wanted.height > 0 ? wanted.height : 400)
        var origin: CGPoint
        switch direction {
        case .down:   // above the control
            size.width = min(size.width, room.width)
            size.height = min(size.height, source.minY - room.minY)
            origin = CGPoint(x: source.midX - size.width / 2, y: source.minY - size.height)
        case .up:     // below it
            size.width = min(size.width, room.width)
            size.height = min(size.height, room.maxY - source.maxY)
            origin = CGPoint(x: source.midX - size.width / 2, y: source.maxY)
        case .left:   // to its right
            size.width = min(size.width, room.maxX - source.maxX)
            size.height = min(size.height, room.height)
            origin = CGPoint(x: source.maxX, y: source.midY - size.height / 2)
        default:      // to its left
            size.width = min(size.width, source.minX - room.minX)
            size.height = min(size.height, room.height)
            origin = CGPoint(x: source.minX - size.width, y: source.midY - size.height / 2)
        }
        origin.x = min(max(origin.x, room.minX), room.maxX - size.width)
        origin.y = min(max(origin.y, room.minY), room.maxY - size.height)
        return CGRect(origin: origin, size: size).integral
    }

    override func presentationTransitionWillBegin() {
        super.presentationTransitionWillBegin()
        guard let container = containerView else { return }
        backdrop.frame = container.bounds
        backdrop.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        backdrop.backgroundColor = .clear
        backdrop.addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(tappedOutside)))
        container.insertSubview(backdrop, at: 0)
    }

    override func containerViewWillLayoutSubviews() {
        super.containerViewWillLayoutSubviews()
        presentedView?.frame = frameOfPresentedViewInContainerView
    }

    override func preferredContentSizeDidChange(forChildContentContainer container: UIContentContainer) {
        super.preferredContentSizeDidChange(forChildContentContainer: container)
        containerView?.setNeedsLayout()
    }

    override var shouldRemovePresentersView: Bool { false }

    @objc private func tappedOutside() { onTapOutside() }
}

/// A square panel comes and goes in a fade, rising a few points as it comes.
final class SquarePanelTransition: NSObject, UIViewControllerAnimatedTransitioning {
    let presenting: Bool

    init(presenting: Bool) { self.presenting = presenting }

    func transitionDuration(using transitionContext: UIViewControllerContextTransitioning?) -> TimeInterval { 0.18 }

    func animateTransition(using context: UIViewControllerContextTransitioning) {
        let duration = transitionDuration(using: context)
        if presenting {
            guard let controller = context.viewController(forKey: .to), let view = context.view(forKey: .to) else {
                context.completeTransition(false)
                return
            }
            view.frame = context.finalFrame(for: controller)
            context.containerView.addSubview(view)
            view.alpha = 0
            view.transform = CGAffineTransform(translationX: 0, y: 6)
            UIView.animate(withDuration: duration, delay: 0, options: .curveEaseOut) {
                view.alpha = 1
                view.transform = .identity
            } completion: { _ in
                context.completeTransition(!context.transitionWasCancelled)
            }
        } else {
            guard let view = context.view(forKey: .from) else {
                context.completeTransition(false)
                return
            }
            UIView.animate(withDuration: duration, delay: 0, options: .curveEaseIn) {
                view.alpha = 0
            } completion: { _ in
                view.removeFromSuperview()
                context.completeTransition(!context.transitionWasCancelled)
            }
        }
    }
}
