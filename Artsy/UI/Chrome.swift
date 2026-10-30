import SwiftUI
import ArtsyEngine

/// The chrome's one visual language: sizes a pen can hit, the colours of the bar, the
/// rail and the panels, and the buttons they are made of.
enum Chrome {
    static let barHeight: CGFloat = 52
    static let railWidth: CGFloat = 56
    static let dockWidth: CGFloat = 300
    /// A window at least this wide can hold the Layers dock beside the canvas.
    static let dockMinimumWindowWidth: CGFloat = 1600
    /// Narrower than this, the bar is the compact one: the quick controls as buttons
    /// with their values, the panel buttons without labels (an iPad in portrait, a phone).
    static let compactBarWidth: CGFloat = 1000
    /// Narrower than this is a phone: no rail, the tools in a strip over the canvas, and
    /// the bar's targets a finger's rather than a pen's.
    static let phoneWidth: CGFloat = 700
    /// The least a pen should have to hit.
    static let target: CGFloat = 44
    /// The least a finger should have to hit, where a phone's bar has no room for more.
    static let compactTarget: CGFloat = 40
    static let panelWidth: CGFloat = 340
    /// Where a panel's arrow goes when it opens from the bar: on the Mac the panel is
    /// asked for below and flipped above the bar by the system; on iPad it is asked for
    /// above, since nothing flips it.
    #if os(macOS)
    static let barPopoverEdge: Edge = .top
    #else
    static let barPopoverEdge: Edge = .bottom
    #endif

    static let background = Color(white: 0.13)
    static let panel = Color(white: 0.16)
    static let control = Color(white: 0.22)
    static let selected = Color.accentColor.opacity(0.35)
    static let text = Color(white: 0.92)
    static let secondaryText = Color(white: 0.62)
    static let hairline = Color(white: 0.28)
    static let font = Font.system(size: 13)
    static let labelFont = Font.system(size: 12)
    static let valueFont = Font.system(size: 12, design: .monospaced)
}

/// A square button a pen can hit: an icon (a symbol or an asset), optionally a label
/// under it, and a selected state.
struct ChromeButton: View {
    var systemImage: String? = nil
    var image: String? = nil
    var label: String? = nil
    var isSelected = false
    var badge: Int? = nil
    var size: CGFloat = Chrome.target
    let help: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            ZStack(alignment: .topTrailing) {
                VStack(spacing: 2) {
                    if let systemImage {
                        Image(systemName: systemImage)
                            .font(.system(size: 20))
                    } else if let image {
                        Image(image)
                            .renderingMode(.template)
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                            .frame(width: 22, height: 22)
                    }
                    if let label {
                        Text(label)
                            .font(.system(size: 10))
                            .lineLimit(1)
                    }
                }
                .frame(width: size, height: size)
                .background(RoundedRectangle(cornerRadius: 10).fill(isSelected ? Chrome.selected : Color.clear))

                if let badge, badge > 0 {
                    Text("\(badge)")
                        .font(.system(size: 10, weight: .semibold, design: .monospaced))
                        .foregroundColor(Chrome.text)
                        .padding(.horizontal, 5)
                        .frame(minWidth: 16, minHeight: 16)
                        .background(Capsule().fill(Chrome.control))
                        .offset(x: 2, y: -2)
                }
            }
            .contentShape(RoundedRectangle(cornerRadius: 10))
        }
        .buttonStyle(.plain)
        .foregroundColor(isSelected ? Chrome.text : Chrome.secondaryText)
        .help(help)
    }
}

/// A panel's title row.
struct PanelHeader<Trailing: View>: View {
    let title: String
    @ViewBuilder let trailing: () -> Trailing
    /// Set by `panelPopover` when the panel is a sheet on a phone rather than a popover:
    /// a sheet that fills the screen shows no way out of itself, so the header carries
    /// a Done button then, and only then.
    @Environment(\.panelDismissal) private var dismissal

    init(_ title: String, @ViewBuilder trailing: @escaping () -> Trailing) {
        self.title = title
        self.trailing = trailing
    }

    var body: some View {
        HStack(spacing: 8) {
            Text(title)
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(Chrome.text)
            Spacer()
            trailing()
            if let dismissal {
                Button("Done", action: dismissal)
                    .buttonStyle(.plain)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(Chrome.text)
                    .padding(.horizontal, 12)
                    .frame(height: 32)
                    .background(Capsule().fill(Chrome.control))
                    .help("Close the panel")
            }
        }
        .padding(.horizontal, 14)
        .frame(height: Chrome.target)
    }
}

/// How a panel presented as a sheet is dismissed, for its header's Done button; nil in
/// a popover, which a tap outside dismisses.
private struct PanelDismissalKey: EnvironmentKey {
    static let defaultValue: (() -> Void)? = nil
}

extension EnvironmentValues {
    var panelDismissal: (() -> Void)? {
        get { self[PanelDismissalKey.self] }
        set { self[PanelDismissalKey.self] = newValue }
    }
}

extension PanelHeader where Trailing == EmptyView {
    init(_ title: String) {
        self.init(title) { EmptyView() }
    }
}

/// A row in a panel's list: a pen-sized button with an icon, a label and a note.
struct PanelRow: View {
    var systemImage: String? = nil
    var image: String? = nil
    let label: String
    var note: String? = nil
    var isSelected = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                if let systemImage {
                    Image(systemName: systemImage)
                        .font(.system(size: 17))
                        .frame(width: 26)
                } else if let image {
                    Image(image)
                        .renderingMode(.template)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(width: 22, height: 22)
                        .frame(width: 26)
                }
                Text(label)
                    .font(Chrome.font)
                    .foregroundColor(Chrome.text)
                Spacer()
                if let note {
                    Text(note)
                        .font(Chrome.valueFont)
                        .foregroundColor(Chrome.secondaryText)
                }
            }
            .padding(.horizontal, 14)
            .frame(height: Chrome.target)
            .frame(maxWidth: .infinity)
            .background(RoundedRectangle(cornerRadius: 8).fill(isSelected ? Chrome.selected : Color.clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundColor(isSelected ? Chrome.text : Chrome.secondaryText)
        .padding(.horizontal, 6)
    }
}

/// A heading between groups of rows.
struct PanelSectionLabel: View {
    let text: String
    init(_ text: String) { self.text = text }
    var body: some View {
        Text(text.uppercased())
            .font(.system(size: 10, weight: .semibold))
            .tracking(0.6)
            .foregroundColor(Chrome.secondaryText)
            .padding(.horizontal, 20)
            .padding(.top, 12)
            .padding(.bottom, 4)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}
