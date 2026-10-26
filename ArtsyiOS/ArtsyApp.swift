import SwiftUI
import ArtsyEngine

/// Artsy on iPad and iPhone: the documents, and a canvas over the one that is open, with
/// the Mac's chrome around it. The engine is the Mac's; see `docs/ios-plan.md`.
@main
struct ArtsyApp: App {
    @StateObject private var model = AppModel()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            if let failure = model.failure {
                Text(failure)
                    .padding()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Chrome.background.ignoresSafeArea())
                    .foregroundColor(Chrome.text)
            } else {
                DocumentBrowser(model: model)
                    .ignoresSafeArea()
            }
        }
        .onChange(of: scenePhase) { _, phase in
            // The open document is kept whenever the app goes to the background; not on
            // every inactive moment, which includes the launch itself
            if phase == .background { model.session?.save() }
        }
    }
}
