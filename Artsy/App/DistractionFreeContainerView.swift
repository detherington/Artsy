import AppKit

class DistractionFreeContainerView: NSView {
    var onEscape: (() -> Void)?

    override var acceptsFirstResponder: Bool { true }

    override func keyDown(with event: NSEvent) {
        // Escape key
        if event.keyCode == 53 {
            onEscape?()
            return
        }
        // Cmd+F to exit
        if event.modifierFlags.contains(.command), event.charactersIgnoringModifiers == "f" {
            onEscape?()
            return
        }
        // Pass through to subviews (canvas)
        super.keyDown(with: event)
    }
}
