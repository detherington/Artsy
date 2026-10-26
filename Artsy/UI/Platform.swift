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
    /// A panel opened from the bar: a popover, or the sheet it becomes on a phone, in the
    /// panel's own colour rather than the system's.
    func panelPresentation() -> some View {
        #if os(iOS)
        presentationBackground(Chrome.panel)
        #else
        self
        #endif
    }

    /// A small popover that stays one on a phone rather than becoming a sheet.
    func popoverStaysPopover() -> some View {
        #if os(iOS)
        presentationCompactAdaptation(.popover)
        #else
        self
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
