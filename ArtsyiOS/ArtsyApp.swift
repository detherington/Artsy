import SwiftUI
import ArtsyEngine

/// Artsy on iPad and iPhone: one canvas, the Pencil, and the bar along the bottom. The
/// engine is the Mac's; this is the first slice of `docs/ios-plan.md`, step 2.
@main
struct ArtsyApp: App {
    @StateObject private var session = PaintingSession()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            CanvasScreen(session: session)
                .preferredColorScheme(.dark)
                .statusBarHidden()
        }
        .onChange(of: scenePhase) { _, phase in
            // The one document is kept whenever the app goes to the background; not on every
            // inactive moment, which includes the launch itself
            if phase == .background { session.save() }
        }
    }
}
