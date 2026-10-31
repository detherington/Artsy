import SwiftUI
import ArtsyEngine
#if canImport(AppKit)
import AppKit
/// The toolkit's image: NSImage on the Mac, UIImage on iPad and iPhone.
typealias PlatformImage = NSImage
#else
import UIKit
typealias PlatformImage = UIImage
#endif

// The chrome is one set of SwiftUI files for the Mac and for iPad and iPhone; what
// differs between the toolkits is kept here, behind one name.

extension PlatformImage {
    /// A rendered tile as the toolkit's image.
    static func from(_ cg: CGImage, size: CGSize) -> PlatformImage {
        #if canImport(AppKit)
        return NSImage(cgImage: cg, size: size)
        #else
        return UIImage(cgImage: cg)
        #endif
    }

    /// The image's pixels, for the engine.
    var cgImageValue: CGImage? {
        #if canImport(AppKit)
        return cgImage(forProposedRect: nil, context: nil, hints: nil)
        #else
        return cgImage
        #endif
    }
}

extension Image {
    init(platformImage: PlatformImage) {
        #if canImport(AppKit)
        self.init(nsImage: platformImage)
        #else
        self.init(uiImage: platformImage)
        #endif
    }
}

/// What the chrome asks of the platform: a browser for a link, somewhere for an error,
/// the system's window colours.
enum Platform {
    /// The system's window background, behind a sheet's form.
    static var windowBackground: Color {
        #if canImport(AppKit)
        Color(nsColor: .windowBackgroundColor)
        #else
        Color(uiColor: .systemBackground)
        #endif
    }

    /// The system's control background, behind a drawn control.
    static var controlBackground: Color {
        #if canImport(AppKit)
        Color(nsColor: .controlBackgroundColor)
        #else
        Color(uiColor: .secondarySystemBackground)
        #endif
    }

    static func open(_ url: URL) {
        #if canImport(AppKit)
        NSWorkspace.shared.open(url)
        #else
        UIApplication.shared.open(url)
        #endif
    }

    /// An error the user should see: an alert on the Mac; the diagnostics log on iPad
    /// until the app has alerts of its own.
    static func present(_ error: Error, doing what: String) {
        DiagnosticsLog.shared.error(error, doing: what)
        #if canImport(AppKit)
        NSAlert(error: error).runModal()
        #endif
    }
}

extension View {
    /// A popover from a control, with `edge` the control's edge it opens from: on iPad a
    /// square one without an arrow, presented by UIKit (`SquarePopover`), which on a
    /// phone becomes a square sheet unless told to stay a popover; the system's on the Mac.
    func chromePopover<Content: View>(isPresented: Binding<Bool>, edge: Edge, gap: CGFloat = 0, staysPopover: Bool = false,
                                      @ViewBuilder content: @escaping () -> Content) -> some View {
        #if os(iOS)
        let direction: UIPopoverArrowDirection
        switch edge {
        case .top: direction = .down
        case .bottom: direction = .up
        case .leading: direction = .right
        case .trailing: direction = .left
        }
        return background(SquarePopover(isPresented: isPresented, direction: direction, gap: gap, staysPopover: staysPopover, content: content))
        #else
        return popover(isPresented: isPresented, arrowEdge: edge, content: content)
        #endif
    }

    /// A panel opened from a control: a popover, or on a phone the sheet it becomes.
    /// The sheet fills the screen and shows no way out of itself, so its header gets a
    /// Done button (`PanelHeader`, through the environment) where a popover, dismissed by
    /// a tap outside it, gets none. The presenting view's size class tells the two apart:
    /// a popover's own contents are compact either way.
    func panelPopover<Panel: View>(isPresented: Binding<Bool>, @ViewBuilder panel: @escaping () -> Panel) -> some View {
        modifier(PanelPopover(isPresented: isPresented, panel: panel))
    }

    /// A panel's frame, for the panels that open from the bar: its size on the Mac, where
    /// a popover is as large as its content. On iPad and iPhone its ideal size, which a
    /// popover takes when the screen has the room and trims when it has not, and which the
    /// sheet a popover becomes on a phone fills: the panel is then never larger than what
    /// holds it, its scrolling part gives way, and nothing is cut off at the corners.
    func panelFrame(width: CGFloat, height: CGFloat) -> some View {
        #if os(macOS)
        frame(width: width, height: height)
        #else
        frame(idealWidth: width, maxWidth: .infinity, idealHeight: height, maxHeight: .infinity)
        #endif
    }

    /// A sheet's frame: fixed on the Mac, where the sheet is a window of its own; no
    /// wider than that on iPad and iPhone, where it fills the sheet it is given.
    func sheetFrame(width: CGFloat, height: CGFloat) -> some View {
        #if os(macOS)
        frame(width: width, height: height)
        #else
        frame(maxWidth: width, maxHeight: .infinity)
        #endif
    }

    /// A toggle as a checkbox on the Mac, a switch where there are no checkboxes.
    func checkboxStyle() -> some View {
        #if canImport(AppKit)
        toggleStyle(.checkbox)
        #else
        toggleStyle(.switch)
        #endif
    }
}

struct PanelPopover<Panel: View>: ViewModifier {
    @Binding var isPresented: Bool
    @ViewBuilder let panel: () -> Panel
    #if os(iOS)
    @Environment(\.horizontalSizeClass) private var sizeClass
    #endif

    /// Whether the popover becomes a sheet here: a phone, or an iPad window too narrow
    /// for popovers.
    private var becomesSheet: Bool {
        #if os(iOS)
        return sizeClass == .compact
        #else
        return false
        #endif
    }

    func body(content: Content) -> some View {
        let dismissal: (() -> Void)? = becomesSheet ? { isPresented = false } : nil
        return content.chromePopover(isPresented: $isPresented, edge: .top, gap: Chrome.popoverGap) {
            panel()
                .environment(\.panelDismissal, dismissal)
        }
    }
}
