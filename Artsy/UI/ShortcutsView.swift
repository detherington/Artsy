import SwiftUI
import ArtsyEngine

/// Every key the app answers to, in one sheet (Help → Keyboard Shortcuts, ⌘/). The table
/// is the one source: the sheet and the tests read it.
enum Shortcuts {
    struct Entry: Identifiable {
        let keys: String
        let does: String
        var id: String { keys + does }
    }

    struct Group: Identifiable {
        let title: String
        let entries: [Entry]
        var id: String { title }
    }

    static let groups: [Group] = [
        Group(title: "Tools", entries: [
            Entry(keys: "B", does: "Brush (Hard Round)"),
            Entry(keys: "E", does: "Eraser"),
            Entry(keys: "G", does: "Fill"),
            Entry(keys: "I", does: "Eyedropper"),
            Entry(keys: "S", does: "Select"),
            Entry(keys: "U", does: "Shape"),
            Entry(keys: "T", does: "Transform"),
            Entry(keys: "H", does: "Pan"),
            Entry(keys: "Space", does: "Pan while held"),
            Entry(keys: "1 – 9", does: "The first nine brushes, as the brush panel numbers them"),
        ]),
        Group(title: "Brush and colour", entries: [
            Entry(keys: "[  ]", does: "Smaller, larger"),
            Entry(keys: "{  }", does: "Less opaque, more opaque"),
            Entry(keys: "X", does: "Swap the colour and the background colour"),
            Entry(keys: "D", does: "Black on white again"),
            Entry(keys: "⌥ click", does: "Pan"),
            Entry(keys: "⇧⌘B", does: "Brush Studio"),
        ]),
        Group(title: "View", entries: [
            Entry(keys: "⌘0", does: "Zoom to fit"),
            Entry(keys: "⌘1", does: "Actual size"),
            Entry(keys: "⌘=  ⌘-", does: "Zoom in, out"),
            Entry(keys: "⌥⌘[  ⌥⌘]", does: "Rotate the canvas left, right"),
            Entry(keys: "⌥⌘0", does: "Reset rotation"),
            Entry(keys: "⌥⌘F", does: "Flip the view"),
            Entry(keys: "⌘'", does: "Grid"),
            Entry(keys: "⌥⌘W", does: "Show wet paint"),
            Entry(keys: "Tab", does: "Hide the interface, and back"),
            Entry(keys: "⌘F", does: "Full screen"),
        ]),
        Group(title: "Edit", entries: [
            Entry(keys: "⌘Z  ⇧⌘Z", does: "Undo, redo"),
            Entry(keys: "⌘X  ⌘C  ⌘V", does: "Cut, copy, paste as a new layer"),
            Entry(keys: "⇧⌘V", does: "Paste in place"),
            Entry(keys: "⌘A  ⌘D", does: "Select all, deselect"),
            Entry(keys: "Delete", does: "Clear inside the selection"),
        ]),
        Group(title: "Files", entries: [
            Entry(keys: "⌘N  ⌘O  ⌘S", does: "New canvas, open, save"),
            Entry(keys: "⌘E", does: "Export PNG"),
            Entry(keys: "⌘,", does: "Settings"),
            Entry(keys: "⌘/", does: "This sheet"),
        ]),
    ]
}

/// The shortcuts, grouped, in the chrome's type.
struct ShortcutsView: View {
    var body: some View {
        VStack(spacing: 0) {
            PanelHeader("Keyboard Shortcuts")
            Divider().overlay(Chrome.hairline)
            DragScroll {
                VStack(spacing: 0) {
                    ForEach(Shortcuts.groups) { group in
                        PanelSectionLabel(group.title)
                        ForEach(group.entries) { entry in
                            HStack(spacing: 14) {
                                Text(entry.keys)
                                    .font(Chrome.valueFont)
                                    .foregroundColor(Chrome.text)
                                    .frame(width: 110, alignment: .leading)
                                Text(entry.does)
                                    .font(Chrome.font)
                                    .foregroundColor(Chrome.secondaryText)
                                    .lineLimit(2)
                                Spacer(minLength: 0)
                            }
                            .padding(.horizontal, 20)
                            .frame(minHeight: 32)
                        }
                    }
                    Spacer(minLength: 12)
                }
                .padding(.bottom, 12)
            }
        }
        .frame(width: 420, height: 640)
        .background(Chrome.panel)
    }
}
