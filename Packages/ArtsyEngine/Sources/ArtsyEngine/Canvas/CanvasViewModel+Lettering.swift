import CoreGraphics
import Foundation

/// The Letter tool's gesture: which part of which balloon it holds, and whether the step
/// to undo it has been saved yet (it is, at the first change, so a tap that only picks a
/// balloon up is not a step).
struct LetteringGesture {
    enum Part { case body, tail, base, width }
    let part: Part
    let balloon: UUID
    var last: CGPoint
    var saved = false
}

/// The Letter tool and the lettering panel. Balloons live on a lettering layer, whose
/// pixels are drawn from them; every change redraws where the balloon was and is, and is
/// a step to undo. The Mac's canvas and the iPad's hand this the canvas points of a press,
/// a drag and a lift, as they do a stroke's.
extension CanvasViewModel {
    /// How near, in screen points, a handle has to be to be taken.
    static let balloonHandleReach: CGFloat = 14

    /// The layer the balloons are on: the topmost with lettering.
    public var letteringLayer: Layer? {
        layerStack?.layers.last { $0.lettering != nil }
    }

    /// The balloons on the lettering layer, bottom first.
    public var balloons: [Balloon] { letteringLayer?.lettering ?? [] }

    /// The balloon the tool has picked up.
    public var selectedBalloon: Balloon? {
        guard let id = selectedBalloonID else { return nil }
        return balloons.first { $0.id == id }
    }

    // MARK: - The tool

    /// A press at `point`: on the picked-up balloon's tail tip, tail base or width handle, takes it;
    /// on a balloon, picks it up to move; elsewhere, puts down the one picked up, or with
    /// none picked up, places a new balloon there and asks the panel for the keyboard.
    public func letteringDown(at point: CGPoint, renderer: CanvasRenderer) {
        let reach = Self.balloonHandleReach / max(transform.scale, 0.01)
        if let selected = selectedBalloon {
            let layout = BalloonLayout(selected)
            if let tail = layout.tailHandle, hypot(tail.x - point.x, tail.y - point.y) <= reach {
                letteringGesture = LetteringGesture(part: .tail, balloon: selected.id, last: point)
                return
            }
            if let base = layout.baseHandle, hypot(base.x - point.x, base.y - point.y) <= reach {
                letteringGesture = LetteringGesture(part: .base, balloon: selected.id, last: point)
                return
            }
            let width = layout.widthHandle
            if hypot(width.x - point.x, width.y - point.y) <= reach {
                letteringGesture = LetteringGesture(part: .width, balloon: selected.id, last: point)
                return
            }
        }
        // The topmost balloon under the press
        if let hit = balloons.last(where: { BalloonLayout($0).contains(point) }) {
            selectedBalloonID = hit.id
            letteringGesture = LetteringGesture(part: .body, balloon: hit.id, last: point)
            return
        }
        if selectedBalloonID != nil {
            selectedBalloonID = nil
            return
        }
        placeBalloon(at: point, renderer: renderer)
    }

    /// The press moved to `point`: moves the balloon, its tail's tip, its tail's base, or its width.
    public func letteringDrag(to point: CGPoint, renderer: CanvasRenderer) {
        guard var gesture = letteringGesture, let layer = letteringLayer else { return }
        let dx = point.x - gesture.last.x, dy = point.y - gesture.last.y
        guard dx != 0 || dy != 0 else { return }
        if !gesture.saved {
            saveUndoSnapshot(renderer: renderer, description: gesture.part == .body ? "Move Balloon" : "Shape Balloon",
                             changing: .layer(layer))
            lastLetteringStep = nil
            gesture.saved = true
        }
        gesture.last = point
        letteringGesture = gesture
        changeBalloon(gesture.balloon, renderer: renderer) { balloon in
            switch gesture.part {
            case .body:
                balloon.center.x += dx
                balloon.center.y += dy
                // The tail goes with it, unless its tip is pinned to its speaker; its tip is
                // pointed on its own
                if let tail = balloon.tail, !balloon.tailPinned { balloon.tail = CGPoint(x: tail.x + dx, y: tail.y + dy) }
            case .tail:
                balloon.tail = point
            case .base:
                // As wide as twice the press's distance from the base's middle, along it
                if let size = BalloonLayout(balloon).baseSize(draggedTo: point) { balloon.look.tailBase = size }
            case .width:
                balloon.wrapWidth = max(balloon.fontSize * 2.5, 2 * (point.x - balloon.center.x))
            }
        }
    }

    /// The press lifted: the layer's thumbnail catches up.
    public func letteringUp(renderer: CanvasRenderer) {
        if letteringGesture?.saved == true, let layer = letteringLayer {
            renderer.updateThumbnail(for: layer)
        }
        // A base set by hand is the next balloon of the kind's too, as the panel's choices are
        if let gesture = letteringGesture, gesture.saved, gesture.part == .base,
           let balloon = balloons.first(where: { $0.id == gesture.balloon }) {
            balloonLooks[balloon.style] = balloon.look
        }
        letteringGesture = nil
    }

    /// A new balloon at `point`, in the style, face and capitals last chosen, picked up,
    /// with the panel asked for the keyboard. The lettering layer is made if there is none.
    public func placeBalloon(at point: CGPoint, renderer: CanvasRenderer) {
        guard let layerStack else { return }
        let existing = letteringLayer
        // Placing is a step: copying the lettering layer, or, if it is made now, nothing
        saveUndoSnapshot(renderer: renderer, description: "Place Balloon", changing: existing.map { .layer($0) } ?? .nothing)
        lastLetteringStep = nil
        let layer: Layer
        if let existing {
            layer = existing
        } else {
            let current = layerStack.activeLayerIndex
            guard let index = try? layerStack.addLayer(above: layerStack.layers.count - 1, name: "Lettering") else {
                undoManager.popLastSnapshot(if: undoManager.lastStepToken)
                return
            }
            layer = layerStack.layers[index]
            layer.lettering = []
            // Locked, so a brush cannot paint into what the next change would redraw;
            // drawing goes on where it was
            layer.isLocked = true
            layerStack.activeLayerIndex = current
        }
        // A drawn font since deleted is not carried on
        let drawn = balloonDrawnFont.flatMap { DrawnFontLibrary.shared.font(id: $0)?.id }
        let balloon = Balloon.new(balloonStyle, at: point, face: balloonFace, drawnFont: drawn,
                                  fontSize: Balloon.fontSize(canvasWidth: canvasSize.width), allCaps: balloonCaps,
                                  look: balloonLook(for: balloonStyle))
        layer.lettering = (layer.lettering ?? []) + [balloon]
        renderer.drawLettering(layer.lettering ?? [], into: layer, in: BalloonLayout(balloon).bounds)
        renderer.updateThumbnail(for: layer)
        selectedBalloonID = balloon.id
        letteringRevision += 1
        balloonWantsKeyboard = true
        markDirty()
    }

    // MARK: - The panel

    /// Changes the picked-up balloon, as a step called `kind`. A run of changes of the same
    /// kind to the same balloon, with nothing else done between, is one step: typing a
    /// sentence is undone at once.
    public func changeSelectedBalloon(_ kind: String, renderer: CanvasRenderer, _ change: (inout Balloon) -> Void) {
        guard let id = selectedBalloonID, let layer = letteringLayer, balloons.contains(where: { $0.id == id }) else { return }
        let token = undoManager.lastStepToken
        if let last = lastLetteringStep, last.balloon == id, last.kind == kind, last.token != nil, last.token == token {
            // Folded into the step already saved
        } else {
            saveUndoSnapshot(renderer: renderer, description: kind, changing: .layer(layer))
            lastLetteringStep = (id, kind, undoManager.lastStepToken)
        }
        changeBalloon(id, renderer: renderer, change)
        renderer.updateThumbnail(for: layer)
    }

    /// The look the next balloon of `style` takes: the one last given a balloon of that kind.
    public func balloonLook(for style: BalloonStyle) -> BalloonLook {
        balloonLooks[style] ?? BalloonLook()
    }

    /// Gives the picked-up balloon `look`, as a step called `kind`, and keeps it for the next
    /// balloon of that kind; with none picked up, only keeps it for the next balloon of the
    /// kind chosen. `addingTail` puts a tail on a balloon that has none, as choosing a tail's
    /// shape does.
    public func setBalloonLook(_ look: BalloonLook, as kind: String, addingTail: Bool = false, renderer: CanvasRenderer?) {
        guard let balloon = selectedBalloon else {
            balloonLooks[balloonStyle] = look
            return
        }
        balloonLooks[balloon.style] = look
        // Nothing to change is no step
        let tails = addingTail && balloon.style.hasTail && balloon.tail == nil
        guard let renderer, balloon.look != look || tails else { return }
        changeSelectedBalloon(kind, renderer: renderer) { b in
            b.look = look
            if addingTail, b.style.hasTail, b.tail == nil {
                b.tail = Balloon.new(b.style, at: b.center, face: b.face, fontSize: b.fontSize, allCaps: b.allCaps).tail
            }
        }
    }

    /// Pins the picked-up balloon's tail tip where it is on the page, so it stays pointing at
    /// its speaker as the balloon moves, or unpins it to go with the balloon; a step either way.
    public func pinSelectedTail(_ pinned: Bool, renderer: CanvasRenderer?) {
        guard let renderer, let balloon = selectedBalloon, balloon.tailPinned != pinned else { return }
        changeSelectedBalloon(pinned ? "Pin Tail" : "Unpin Tail", renderer: renderer) { $0.tailPinned = pinned }
    }

    /// Makes the next balloon `style`, and the picked-up one too, as a step: it takes the new
    /// kind's shape and tail, keeping its line and fill, and a balloon that comes to speak
    /// gets a tail.
    public func restyleSelectedBalloon(_ style: BalloonStyle, renderer: CanvasRenderer?) {
        balloonStyle = style
        guard let selected = selectedBalloon, selected.style != style, let renderer else { return }
        let kept = balloonLook(for: style)
        changeSelectedBalloon("Balloon Style", renderer: renderer) { balloon in
            let before = balloon.style
            balloon.style = style
            balloon.look.shape = kept.shape
            balloon.look.tail = kept.tail
            if style.hasTail, !before.hasTail, balloon.tail == nil {
                balloon.tail = Balloon.new(style, at: balloon.center, face: balloon.face, fontSize: balloon.fontSize,
                                           allCaps: balloon.allCaps).tail
            }
        }
    }

    /// Takes the picked-up balloon off the page.
    public func deleteSelectedBalloon(renderer: CanvasRenderer) {
        guard let id = selectedBalloonID, let layer = letteringLayer,
              let balloon = balloons.first(where: { $0.id == id }) else { return }
        saveUndoSnapshot(renderer: renderer, description: "Delete Balloon", changing: .layer(layer))
        lastLetteringStep = nil
        layer.lettering = balloons.filter { $0.id != id }
        renderer.drawLettering(layer.lettering ?? [], into: layer, in: BalloonLayout(balloon).bounds)
        renderer.updateThumbnail(for: layer)
        selectedBalloonID = nil
        letteringRevision += 1
        markDirty()
    }

    /// `id`'s balloon changed by `change`, and drawn again where it was and is now.
    private func changeBalloon(_ id: UUID, renderer: CanvasRenderer, _ change: (inout Balloon) -> Void) {
        guard let layer = letteringLayer, var all = layer.lettering, let index = all.firstIndex(where: { $0.id == id }) else { return }
        let before = BalloonLayout(all[index]).bounds
        change(&all[index])
        guard all[index] != layer.lettering?[index] else { return }
        layer.lettering = all
        renderer.drawLettering(all, into: layer, in: before.union(BalloonLayout(all[index]).bounds))
        letteringRevision += 1
        markDirty()
    }
}
