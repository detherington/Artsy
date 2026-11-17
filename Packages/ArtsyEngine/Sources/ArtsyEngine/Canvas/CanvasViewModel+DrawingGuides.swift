import CoreGraphics

/// A drawing guide's handle: a vanishing point or the horizon, an end or the middle of the
/// ruler, the ellipse's centre or the end of one of its axes.
public enum GuideHandle: Equatable {
    case perspective(PerspectiveGuide.Handle)
    case ruler(RulerGuide.Handle)
    case ellipse(EllipseGuide.Handle)
    /// The clear area of speed or focus lines being laid out.
    case lines(EllipseGuide.Handle)
}

/// The drawing guides (perspective, the ruler, the ellipse template), edited: the Mac's
/// canvas and the iPad's pass presses on as canvas points, as they do for the Letter tool,
/// while `editingGuide` is set; and, on the Mac, a ⌘-press, as picks up a guide line. A
/// drag changes the guides at once, so the overlays follow it. The guides take no undo
/// step (they change no pixels) but do mark the document changed.
extension CanvasViewModel {
    /// Start moving `guide`'s handles. One the canvas does not have yet is laid out across
    /// the screen of `viewSize` first (perspective with two points); one hidden is shown.
    public func editGuide(_ guide: DrawingGuide, viewSize: CGSize) {
        switch guide {
        case .perspective:
            if guides.perspective == nil {
                setPerspective(points: 2, viewSize: viewSize)
            } else if guides.perspective?.isShown == false {
                changeGuides { $0.perspective?.isShown = true }
            }
        case .ruler:
            if guides.ruler == nil {
                // Across the middle of the screen, three fifths of it wide
                let ruler = RulerGuide(start: onScreen(0.2, 0.5, viewSize), end: onScreen(0.8, 0.5, viewSize))
                changeGuides { $0.ruler = ruler }
            } else if guides.ruler?.isShown == false {
                changeGuides { $0.ruler?.isShown = true }
            }
        case .ellipse:
            if guides.ellipse == nil {
                // In the middle of the screen, two fifths of it wide, at 30°
                let ellipse = EllipseGuide(centre: onScreen(0.5, 0.5, viewSize), axisEnd: onScreen(0.7, 0.5, viewSize),
                                           degree: 30)
                changeGuides { $0.ellipse = ellipse }
            } else if guides.ellipse?.isShown == false {
                changeGuides { $0.ellipse?.isShown = true }
            }
        case .lines:
            startLines(comicLines?.kind ?? .focus, viewSize: viewSize)
            return
        }
        guideGesture = nil
        editingGuide = guide
    }

    /// Ends editing; speed or focus lines being laid out are let go, unmade.
    public func endGuideEditing() {
        guideGesture = nil
        if editingGuide == .lines { comicLines = nil }
        editingGuide = nil
    }

    // MARK: - Speed and focus lines

    /// Starts laying out lines of `kind`: round a clear area in the middle of the screen of
    /// `viewSize`, a fifth of it wide, or round the one they had if they are being laid out
    /// already, kept as they were but for their kind.
    public func startLines(_ kind: ComicLines.Kind, viewSize: CGSize) {
        if let current = comicLines {
            if current.kind != kind {
                var changed = ComicLines.laidOut(kind: kind, clear: current.clear, canvasSize: canvasSize)
                changed.variety = current.variety
                changed.seed = current.seed
                comicLines = changed
            }
        } else {
            let clear = EllipseGuide(centre: onScreen(0.5, 0.5, viewSize), axisEnd: onScreen(0.6, 0.5, viewSize), degree: 60)
            comicLines = ComicLines.laidOut(kind: kind, clear: clear, canvasSize: canvasSize)
        }
        guideGesture = nil
        editingGuide = .lines
    }

    /// The lines laid out, made into a layer of their own above the current one in the
    /// current colour, inside the selection if there is one: one step to undo. Laying out
    /// ends.
    public func makeLines(renderer: CanvasRenderer) throws {
        guard let lines = comicLines else { return }
        try lines.addLayer(to: self, renderer: renderer, colour: currentColor, clip: selectionPath)
        DiagnosticsLog.shared.note(.app, "made \(lines.kind.layerName.lowercased()): \(lines.count) asked, \(lines.lines(canvasSize: canvasSize).count) drawn")
        endGuideEditing()
    }

    public func cancelLines() {
        if editingGuide == .lines { endGuideEditing() } else { comicLines = nil }
    }

    /// The canvas point at a fraction `x` across and `y` up the screen of `viewSize` (the
    /// engine's view space runs y up).
    private func onScreen(_ x: CGFloat, _ y: CGFloat, _ viewSize: CGSize) -> CGPoint {
        transform.viewToCanvas(CGPoint(x: viewSize.width * x, y: viewSize.height * y), viewSize: viewSize)
    }

    /// Perspective with `count` points (1 to 3), keeping its horizon; laid out across the
    /// screen of `viewSize` where it has no points to keep.
    public func setPerspective(points count: Int, viewSize: CGSize) {
        // A tenth in from the screen's sides, across its middle; a third below, near its foot
        let current = guides.perspective ?? PerspectiveGuide(points: [])
        let laidOut = current.with(points: count, left: onScreen(0.1, 0.5, viewSize), right: onScreen(0.9, 0.5, viewSize),
                                   below: onScreen(0.5, 0.08, viewSize))
        changeGuides { $0.perspective = laidOut }
    }

    /// `guide` taken away, and its editing ended if it was being edited.
    public func removeGuide(_ guide: DrawingGuide) {
        if editingGuide == guide { endGuideEditing() }
        switch guide {
        case .perspective: changeGuides { $0.perspective = nil }
        case .ruler: changeGuides { $0.ruler = nil }
        case .ellipse: changeGuides { $0.ellipse = nil }
        case .lines: comicLines = nil
        }
    }

    /// The handle within reach of `point` at the current zoom: the edited guide's, or while
    /// none is edited, any shown guide's, the nearest.
    public func guideHandle(near point: CGPoint) -> GuideHandle? {
        let reach = DrawingGuide.handleReach / max(transform.scale, 0.01)
        let only = editingGuide
        var candidates: [(handle: GuideHandle, at: CGPoint)] = []
        if only == nil || only == .perspective, let perspective = guides.perspective, perspective.isShown,
           let handle = perspective.handle(near: point, reach: reach), let at = perspective.position(of: handle) {
            candidates.append((.perspective(handle), at))
        }
        if only == nil || only == .ruler, let ruler = guides.ruler, ruler.isShown,
           let handle = ruler.handle(near: point, reach: reach) {
            candidates.append((.ruler(handle), ruler.position(of: handle)))
        }
        if only == nil || only == .ellipse, let ellipse = guides.ellipse, ellipse.isShown,
           let handle = ellipse.handle(near: point, reach: reach) {
            candidates.append((.ellipse(handle), ellipse.position(of: handle)))
        }
        // Lines being laid out only while they are
        if only == .lines, let clear = comicLines?.clear, let handle = clear.handle(near: point, reach: reach) {
            candidates.append((.lines(handle), clear.position(of: handle)))
        }
        return candidates.min { hypot($0.at.x - point.x, $0.at.y - point.y) < hypot($1.at.x - point.x, $1.at.y - point.y) }?.handle
    }

    /// A press at `point`: picks up the handle within reach, if any, and says whether it did.
    @discardableResult
    public func guideHandleDown(at point: CGPoint) -> Bool {
        guard let handle = guideHandle(near: point) else { return false }
        guideGesture = (handle, point)
        return true
    }

    public func guideHandleDrag(to point: CGPoint) {
        guard let gesture = guideGesture else { return }
        let delta = CGVector(dx: point.x - gesture.last.x, dy: point.y - gesture.last.y)
        switch gesture.handle {
        case .perspective(let handle): guides.perspective?.move(handle, by: delta)
        case .ruler(let handle): guides.ruler?.move(handle, by: delta)
        case .ellipse(let handle): guides.ellipse?.move(handle, by: delta)
        case .lines(let handle): comicLines?.clear.move(handle, by: delta)
        }
        guideGesture = (gesture.handle, point)
    }

    public func guideHandleUp() {
        guard let gesture = guideGesture else { return }
        guideGesture = nil
        // Lines being laid out are not in the document until they are made
        if case .lines = gesture.handle { return }
        markDirty()
    }
}
