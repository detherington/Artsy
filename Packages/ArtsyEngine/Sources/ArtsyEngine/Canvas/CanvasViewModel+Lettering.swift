import CoreGraphics
import Foundation

/// The Letter tool's gesture: which part of which balloon it holds, and whether the step
/// to undo it has been saved yet (it is, at the first change, so a tap that only picks a
/// balloon up is not a step).
struct LetteringGesture {
    enum Part { case body, tail, width }
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

    /// A press at `point`: on the picked-up balloon's tail tip or width handle, takes it;
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

    /// The press moved to `point`: moves the balloon, its tail's tip, or its width.
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
                // The tail goes with it; its tip is pointed on its own
                if let tail = balloon.tail { balloon.tail = CGPoint(x: tail.x + dx, y: tail.y + dy) }
            case .tail:
                balloon.tail = point
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
                                  fontSize: Balloon.fontSize(canvasWidth: canvasSize.width), allCaps: balloonCaps)
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
