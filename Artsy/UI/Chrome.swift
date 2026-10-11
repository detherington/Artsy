import SwiftUI

/// The chrome's one visual language: sizes a pen can hit, the colours of the bar, the
/// rail and the panels, and the buttons they are made of.
enum Chrome {
    static let barHeight: CGFloat = 52
    static let railWidth: CGFloat = 56
    static let dockWidth: CGFloat = 300
    /// A window at least this wide can hold the Layers dock beside the canvas.
    static let dockMinimumWindowWidth: CGFloat = 1600
    /// The least a pen should have to hit.
    static let target: CGFloat = 44
    static let panelWidth: CGFloat = 340

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
                .frame(width: Chrome.target, height: Chrome.target)
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
        }
        .padding(.horizontal, 14)
        .frame(height: Chrome.target)
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
