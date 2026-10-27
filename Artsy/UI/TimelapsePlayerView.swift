import SwiftUI
import AVKit
import ArtsyEngine

/// The time-lapse replayed: the movie in a player, its length, frames and size above,
/// Export at full length or 30 seconds, and Done.
struct TimelapsePlayerView: View {
    let movie: TimelapseMovie
    let name: String
    let export: (TimelapseMovie.Length) -> Void
    let done: () -> Void
    @State private var player = AVPlayer()
    @State private var watching: NSKeyValueObservation?

    var body: some View {
        VStack(spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(name)
                        .font(.headline)
                    Text(TimelapseRecorder.describe(duration: movie.duration) + ", " + String(movie.frames) + " frames, "
                         + String(Int(movie.size.width)) + " × " + String(Int(movie.size.height)))
                        .font(.system(size: 12))
                        .foregroundColor(.secondary)
                }
                Spacer()
                Menu("Export") {
                    Button("Full Length…") { export(.full) }
                    Button("30 Seconds…") { export(.thirtySeconds) }
                }
                .fixedSize()
                Button("Done", action: done)
                    .keyboardShortcut(.cancelAction)
            }
            VideoPlayer(player: player)
                .aspectRatio(movie.size.width / movie.size.height, contentMode: .fit)
                .background(Color.black)
        }
        .padding(16)
        .onAppear {
            let item = movie.playerItem()
            // A replay that cannot play says why in the diagnostics
            watching = item.observe(\.status) { item, _ in
                if item.status == .failed {
                    let error = item.error as NSError?
                    let underlying = error?.userInfo[NSUnderlyingErrorKey] as? NSError
                    DiagnosticsLog.shared.note(.error, "time-lapse replay failed: " + (error?.localizedDescription ?? "no reason given")
                                               + (error.map { " (\($0.domain) \($0.code))" } ?? "")
                                               + (underlying.map { " from \($0.domain) \($0.code)" } ?? ""))
                }
            }
            player.replaceCurrentItem(with: item)
            player.play()
        }
        .onDisappear { player.pause() }
    }
}

/// An export under way: its progress for the view, and the task to cancel.
final class TimelapseExport: ObservableObject {
    @Published var fraction: Double = 0
    var task: Task<Void, Never>?

    func cancel() { task?.cancel() }
}

/// The export's progress, with Cancel.
struct TimelapseExportView: View {
    @ObservedObject var export: TimelapseExport
    let name: String

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Exporting the time-lapse of " + name + "…")
                .font(.headline)
            ProgressView(value: export.fraction)
            HStack {
                Spacer()
                Button("Cancel") { export.cancel() }
                    .keyboardShortcut(.cancelAction)
            }
        }
        .padding(20)
        .frame(width: 360)
    }
}
