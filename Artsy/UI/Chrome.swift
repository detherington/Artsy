import SwiftUI
import ArtsyEngine
#if canImport(AppKit)
import AppKit
#else
import UIKit
#endif

/// The chrome's one visual language: sizes a pen can hit, and a system in the Bauhaus
/// manner that keeps out of the painting's way. Ink or paper for the ground, one grey
/// for everything secondary, hairlines to divide, and one red, the square that marks
/// what is active. Futura, the geometric face of the period that every Mac and iPhone
/// ships with, in Medium and Bold, with labels in lowercase after Bayer's universal
/// alphabet. Square corners on everything; the colour swatch is the only circle. The
/// colours have a light and a dark side, which the appearance setting picks between.
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
    /// Air between a control and the popover that opens from it.
    static let popoverGap: CGFloat = 8

    // MARK: - Colour

    /// The ground: ink, or paper in the light appearance.
    static let background = Color(light: Color(hex: 0xF4F4F2), dark: Color(hex: 0x121212))
    /// A panel laid on the ground, a step off it.
    static let panel = Color(light: Color(hex: 0xFFFFFF), dark: Color(hex: 0x181818))
    /// The quiet fill of a control that needs a surface of its own: a text field, a tile.
    static let control = Color(light: Color(hex: 0xEAEAE7), dark: Color(hex: 0x1F1F1F))
    /// A selection where the mark alone cannot carry it, a row or a swatch: a whisper of a fill.
    static let selected = Color(light: Color.black.opacity(0.06), dark: Color.white.opacity(0.08))
    static let text = Color(light: Color(hex: 0x111111), dark: Color(hex: 0xF2F2F2))
    static let secondaryText = Color(light: Color(hex: 0x6F6F6F), dark: Color(hex: 0x8C8C8C))
    static let hairline = Color(light: Color(hex: 0xD8D8D5), dark: Color(hex: 0x262626))
    /// A slider's track: a line one can see.
    static let track = Color(light: Color(hex: 0xC4C4C0), dark: Color(hex: 0x3A3A3A))
    /// The one colour: what is active, and the way on.
    static let accent = Color(hex: 0xE03A2F)
    /// The other two of the mark's three, used nowhere else.
    static let markYellow = Color(hex: 0xF2C230)
    static let markBlue = Color(hex: 0x2457C5)
    /// The size of the square that marks what is active.
    static let mark: CGFloat = 8

    // MARK: - Type

    /// Futura, the system's own, at a size: Medium for the words, Bold for the names.
    static func futura(_ size: CGFloat, bold: Bool = false) -> Font {
        .custom(bold ? "Futura-Bold" : "Futura-Medium", size: size)
    }

    static let font = futura(13)
    static let labelFont = futura(12)
    static let valueFont = futura(13).monospacedDigit()
    /// A panel's title, lowercase.
    static let titleFont = futura(16, bold: true)
    /// A section's label, lowercase and tracked.
    static let sectionFont = futura(12)
    static let sectionTracking: CGFloat = 1

    // MARK: - Appearance

    #if canImport(AppKit)
    /// The appearance the preference asks for; nil follows the system.
    static var appearance: NSAppearance? {
        switch AppPreferences.shared.appearance {
        case .system: return nil
        case .dark: return NSAppearance(named: .darkAqua)
        case .light: return NSAppearance(named: .aqua)
        }
    }

    /// The app and every window on the preference; called at launch and when it changes.
    static func applyAppearance() {
        NSApp.appearance = appearance
    }
    #else
    /// The style the preference asks for; unspecified follows the system.
    static var interfaceStyle: UIUserInterfaceStyle {
        switch AppPreferences.shared.appearance {
        case .system: return .unspecified
        case .dark: return .dark
        case .light: return .light
        }
    }

    /// The same, for the SwiftUI root, which sets the scene's appearance from it; nil
    /// follows the system.
    static var colorScheme: ColorScheme? {
        switch AppPreferences.shared.appearance {
        case .system: return nil
        case .dark: return .dark
        case .light: return .light
        }
    }
    #endif
}

extension Color {
    /// A colour from its hex, as written in a design.
    init(hex: UInt32) {
        self.init(red: Double((hex >> 16) & 0xFF) / 255, green: Double((hex >> 8) & 0xFF) / 255, blue: Double(hex & 0xFF) / 255)
    }

    /// A colour with a side for each appearance.
    init(light: Color, dark: Color) {
        #if canImport(AppKit)
        self.init(nsColor: NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? NSColor(dark) : NSColor(light)
        })
        #else
        self.init(uiColor: UIColor { traits in
            traits.userInterfaceStyle == .dark ? UIColor(dark) : UIColor(light)
        })
        #endif
    }
}

/// The mark: a square in the one colour, beside what is active.
struct Mark: View {
    var body: some View {
        Rectangle()
            .fill(Chrome.accent)
            .frame(width: Chrome.mark, height: Chrome.mark)
    }
}

/// The app's mark and name: the three forms in the three colours, and "artsy".
struct BrandMark: View {
    var size: CGFloat = 20

    var body: some View {
        HStack(spacing: size * 0.6) {
            HStack(spacing: size * 0.2) {
                Triangle()
                    .fill(Chrome.markYellow)
                    .frame(width: size * 0.6, height: size * 0.6)
                Rectangle()
                    .fill(Chrome.accent)
                    .frame(width: size * 0.6, height: size * 0.6)
                Circle()
                    .fill(Chrome.markBlue)
                    .frame(width: size * 0.6, height: size * 0.6)
            }
            Text("artsy")
                .font(Chrome.futura(size, bold: true))
                .foregroundColor(Chrome.text)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Artsy")
    }
}

struct Triangle: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.midX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
        path.closeSubpath()
        return path
    }
}

/// A square button a pen can hit: an icon (a symbol or an asset), optionally a label
/// under it, and the mark beside it when it is selected.
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
                VStack(spacing: 3) {
                    if let systemImage {
                        Image(systemName: systemImage)
                            .font(.system(size: 19, weight: .regular))
                    } else if let image {
                        Image(image)
                            .renderingMode(.template)
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                            .frame(width: 21, height: 21)
                    }
                    if let label {
                        Text(label.lowercased())
                            .font(Chrome.futura(10))
                            .lineLimit(1)
                    }
                }
                .frame(width: size, height: size)

                if let badge, badge > 0 {
                    Text("\(badge)")
                        .font(Chrome.futura(10))
                        .foregroundColor(Chrome.secondaryText)
                        .offset(x: -4, y: 4)
                }
            }
            .overlay(alignment: .leading) {
                if isSelected {
                    Mark().offset(x: -2)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundColor(isSelected ? Chrome.text : Chrome.secondaryText)
        .help(help)
    }
}

/// A choice among a few in a row, a grade or a symmetry: its word, or its icon and word,
/// with a line under it in the one colour when it is the one chosen.
struct SquareChoice: View {
    var systemImage: String? = nil
    let text: String
    let isSelected: Bool
    var height: CGFloat = 36
    var font: Font = Chrome.valueFont
    let help: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 3) {
                if let systemImage {
                    Image(systemName: systemImage)
                        .font(.system(size: 17, weight: .regular))
                }
                Text(text)
                    .font(font)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity)
            .frame(height: height)
            .overlay(alignment: .bottom) {
                Rectangle()
                    .fill(isSelected ? Chrome.accent : Color.clear)
                    .frame(height: 2)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundColor(isSelected ? Chrome.text : Chrome.secondaryText)
        .help(help)
    }
}

/// A slider's track as a line with the mark on it: a tap or a drag anywhere along it
/// puts the mark there. The position runs 0 to 1 along the track.
struct TrackSlider: View {
    @Binding var position: Double
    var onEditingChanged: (Bool) -> Void = { _ in }
    @State private var dragging = false

    var body: some View {
        GeometryReader { geometry in
            let run = max(1, geometry.size.width - Chrome.mark)
            ZStack(alignment: .leading) {
                Rectangle()
                    .fill(Chrome.track)
                    .frame(height: 1)
                Mark()
                    .offset(x: CGFloat(min(1, max(0, position))) * run)
            }
            .frame(maxHeight: .infinity, alignment: .center)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { drag in
                        if !dragging {
                            dragging = true
                            onEditingChanged(true)
                        }
                        position = Double(min(1, max(0, (drag.location.x - Chrome.mark / 2) / run)))
                    }
                    .onEnded { _ in
                        dragging = false
                        onEditingChanged(false)
                    }
            )
        }
        .frame(height: 24)
    }
}

/// A panel's title row, the title in lowercase.
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
            Text(title.lowercased())
                .font(Chrome.titleFont)
                .foregroundColor(Chrome.text)
            Spacer()
            trailing()
            if let dismissal {
                Button("done", action: dismissal)
                    .buttonStyle(.plain)
                    .font(Chrome.futura(14, bold: true))
                    .foregroundColor(Chrome.accent)
                    .padding(.horizontal, 8)
                    .frame(height: 32)
                    .help("Close the panel")
            }
        }
        .padding(.horizontal, 16)
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

/// A row in a panel's list: a pen-sized button with an icon, a label and a note, and the
/// mark before it when it is selected.
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
                        .font(.system(size: 16, weight: .regular))
                        .frame(width: 26)
                } else if let image {
                    Image(image)
                        .renderingMode(.template)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(width: 20, height: 20)
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
            .padding(.horizontal, 16)
            .frame(height: Chrome.target)
            .frame(maxWidth: .infinity)
            .overlay(alignment: .leading) {
                if isSelected {
                    Mark().padding(.leading, 4)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundColor(isSelected ? Chrome.text : Chrome.secondaryText)
    }
}

/// A heading between groups of rows: lowercase, tracked.
struct PanelSectionLabel: View {
    let text: String
    init(_ text: String) { self.text = text }
    var body: some View {
        Text(text.lowercased())
            .font(Chrome.sectionFont)
            .tracking(Chrome.sectionTracking)
            .foregroundColor(Chrome.secondaryText)
            .frame(height: 14)
            .padding(.horizontal, 16)
            .padding(.top, 12)
            .padding(.bottom, 4)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// A choice from a list: the chosen word and a small triangle inside a hairline box, and
/// the system's menu, with its options, opening from it.
struct SquareMenu<Options: View>: View {
    let title: String
    var minWidth: CGFloat = 0
    @ViewBuilder let options: () -> Options

    init(_ title: String, minWidth: CGFloat = 0, @ViewBuilder options: @escaping () -> Options) {
        self.title = title
        self.minWidth = minWidth
        self.options = options
    }

    var body: some View {
        Menu {
            options()
        } label: {
            HStack(spacing: 10) {
                Text(title)
                    .font(Chrome.font)
                    .foregroundColor(Chrome.text)
                    .lineLimit(1)
                Spacer(minLength: 0)
                Image(systemName: "arrowtriangle.down.fill")
                    .font(.system(size: 8))
                    .foregroundColor(Chrome.secondaryText)
            }
            .padding(.horizontal, 10)
            .frame(minWidth: minWidth)
            .frame(height: 32)
            .overlay(Rectangle().strokeBorder(Chrome.hairline, lineWidth: 1))
            .contentShape(Rectangle())
        }
        .buttonStyle(SquareMenuStyle())
        .menuIndicator(.hidden)
        .fixedSize()
    }

    private struct SquareMenuStyle: ButtonStyle {
        func makeBody(configuration: Configuration) -> some View {
            configuration.label
                .opacity(configuration.isPressed ? 0.6 : 1)
        }
    }
}

extension View {
    /// A text field in the chrome: the value in a hairline box, no plate or rounding.
    func squareField(width: CGFloat) -> some View {
        textFieldStyle(.plain)
            .font(Chrome.valueFont)
            .foregroundColor(Chrome.text)
            .padding(.horizontal, 6)
            .frame(width: width, height: 28)
            .overlay(Rectangle().strokeBorder(Chrome.hairline, lineWidth: 1))
    }
}
