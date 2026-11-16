import CoreGraphics

/// Perspective guides, edited: the Mac's canvas and the iPad's pass presses on as canvas
/// points, as they do for the Letter tool, while `isEditingPerspective`; and, on the Mac,
/// a ⌘-press, as picks up a guide line. A drag changes the guides at once, so the overlays
/// follow it. The guides take no undo step (they change no pixels) but do mark the
/// document changed.
extension CanvasViewModel {
    /// Start moving the vanishing points. A canvas with no perspective gets two-point
    /// perspective laid out across the screen of `viewSize`; one hidden is shown.
    public func editPerspective(viewSize: CGSize) {
        if guides.perspective == nil {
            setPerspective(points: 2, viewSize: viewSize)
        } else if guides.perspective?.isShown == false {
            changeGuides { $0.perspective?.isShown = true }
        }
        isEditingPerspective = true
    }

    public func endPerspectiveEditing() {
        perspectiveGesture = nil
        isEditingPerspective = false
    }

    /// Perspective with `count` points (1 to 3), keeping its horizon; laid out across the
    /// screen of `viewSize` where it has no points to keep.
    public func setPerspective(points count: Int, viewSize: CGSize) {
        func onScreen(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
            transform.viewToCanvas(CGPoint(x: viewSize.width * x, y: viewSize.height * y), viewSize: viewSize)
        }
        // A tenth in from the screen's sides, across its middle; a third below, near its foot
        // (the engine's view space runs y up)
        let current = guides.perspective ?? PerspectiveGuide(points: [])
        let laidOut = current.with(points: count, left: onScreen(0.1, 0.5), right: onScreen(0.9, 0.5),
                                   below: onScreen(0.5, 0.08))
        changeGuides { $0.perspective = laidOut }
    }

    public func removePerspective() {
        endPerspectiveEditing()
        changeGuides { $0.perspective = nil }
    }

    /// The handle within reach of `point` at the current zoom, if the perspective shows.
    public func perspectiveHandle(near point: CGPoint) -> PerspectiveGuide.Handle? {
        guard let perspective = guides.perspective, perspective.isShown else { return nil }
        return perspective.handle(near: point, reach: PerspectiveGuide.handleReach / max(transform.scale, 0.01))
    }

    /// A press at `point`: picks up the handle within reach, if any, and says whether it did.
    @discardableResult
    public func perspectiveDown(at point: CGPoint) -> Bool {
        guard let handle = perspectiveHandle(near: point) else { return false }
        perspectiveGesture = (handle, point)
        return true
    }

    public func perspectiveDrag(to point: CGPoint) {
        guard let gesture = perspectiveGesture else { return }
        let delta = CGVector(dx: point.x - gesture.last.x, dy: point.y - gesture.last.y)
        guides.perspective?.move(gesture.handle, by: delta)
        perspectiveGesture = (gesture.handle, point)
    }

    public func perspectiveUp() {
        guard perspectiveGesture != nil else { return }
        perspectiveGesture = nil
        markDirty()
    }
}
