import SwiftUI
import ArtsyEngine

/// What the start screen can do, as each app does it: the Mac in windows and panels,
/// iPad and iPhone in screens and sheets over it.
struct StartActions {
    /// A canvas of this size, now.
    var newCanvas: (CGSize) -> Void = { _ in }
    /// The size dialog, for a width and height of one's own.
    var customCanvas: () -> Void = {}
    var open: (RecentCanvases.Entry) -> Void = { _ in }
    /// The open panel, or the Files browser.
    var browse: () -> Void = {}
    var browseTitle = "Open…"
    var reveal: ((RecentCanvases.Entry) -> Void)?
    /// Whether this document can be renamed from here, and the renaming.
    var canRename: (RecentCanvases.Entry) -> Bool = { _ in false }
    var rename: (RecentCanvases.Entry, String) -> Void = { _, _ in }
    /// A canvas from a photo: from the photo library, and from an image file.
    var fromPhotos: (() -> Void)?
    var fromImageFile: (() -> Void)?
}

/// Where each app starts, and comes back to with nothing open: the canvases opened
/// lately as a grid of their own thumbnails, a row of sizes that make a canvas in one
/// tap, the way to a document elsewhere, and a canvas from a photo. See
/// `docs/start-screen-plan.md`.
struct StartView: View {
    @ObservedObject var recents: RecentCanvases
    /// The largest side this device takes; sizes beyond it are not offered.
    let maxSide: Int
    /// The pixels of the screen the app is on, as it is held now, for the "This screen"
    /// size; nil when there is no screen to ask. Asked again whenever the screen draws,
    /// so a turn or a fold is followed.
    let screenPixels: () -> CGSize?
    let actions: StartActions
    @ObservedObject private var prefs = AppPreferences.shared
    @State private var renaming: RecentCanvases.Entry?
    @State private var newName = ""
    /// Goes up when the window moves to another screen, so the sizes are asked again.
    @State private var screenChanges = 0

    init(recents: RecentCanvases, maxSide: Int = LayerStack.maxCanvasSide, screenPixels: @escaping () -> CGSize? = { nil },
         actions: StartActions) {
        self.recents = recents
        self.maxSide = maxSide
        self.screenPixels = screenPixels
        self.actions = actions
    }

    static let dim = Chrome.text.opacity(0.55)

    var body: some View {
        GeometryReader { geometry in
            let phone = geometry.size.width < Chrome.phoneWidth
            ScrollView {
                VStack(alignment: .leading, spacing: phone ? 22 : 28) {
                    #if os(iOS)
                    Text("Artsy")
                        .font(.system(size: 22, weight: .semibold))
                        .padding(.top, 4)
                    #endif
                    section("New canvas") { newRow(phone: phone) }
                    section("Recent") { recentGrid(phone: phone) }
                    HStack(spacing: 10) {
                        Button(actions.browseTitle, action: actions.browse)
                            .buttonStyle(.bordered)
                        if let photos = actions.fromPhotos, let file = actions.fromImageFile {
                            Menu("From a photo…") {
                                Button("Photos…", action: photos)
                                Button("Files…", action: file)
                            }
                            .buttonStyle(.bordered)
                        } else if let one = actions.fromPhotos ?? actions.fromImageFile {
                            Button("From a photo…", action: one)
                                .buttonStyle(.bordered)
                        }
                    }
                }
                .padding(phone ? 16 : 28)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .background(Chrome.background.ignoresSafeArea())
        .foregroundColor(Chrome.text)
        #if os(macOS)
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didChangeScreenNotification)) { _ in screenChanges += 1 }
        #endif
        .alert("Rename", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } }),
               presenting: renaming) { entry in
            TextField("Name", text: $newName)
            Button("Rename") { actions.rename(entry, newName.trimmingCharacters(in: .whitespaces)) }
            Button("Cancel", role: .cancel) {}
        } message: { _ in
            Text("The canvas keeps its place in the list.")
        }
    }

    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(.system(size: 13))
                .foregroundColor(Self.dim)
            content()
        }
    }

    // MARK: - New canvas

    struct Size: Identifiable, Equatable {
        let id: String
        let name: String
        let width: Int
        let height: Int
    }

    private var sizes: [Size] {
        _ = screenChanges
        return Self.sizes(last: prefs.lastCanvasSize, screen: screenPixels(), maxSide: maxSide)
    }

    /// The sizes offered: the size used last; this screen's pixels, the way the device is
    /// held, when there is a screen to ask; then the presets. A size the device cannot
    /// take is left out, and so is one that repeats an earlier tile.
    static func sizes(last: CGSize, screen: CGSize?, maxSide: Int) -> [Size] {
        var sizes = [Size(id: "last", name: "Same as last", width: Int(last.width), height: Int(last.height))]
        func offer(_ size: Size) {
            guard max(size.width, size.height) <= maxSide, size.width > 0, size.height > 0,
                  !sizes.contains(where: { $0.width == size.width && $0.height == size.height }) else { return }
            sizes.append(size)
        }
        if let screen {
            offer(Size(id: "screen", name: "This screen", width: Int(screen.width.rounded()), height: Int(screen.height.rounded())))
        }
        for preset in CanvasSizePreset.presets {
            offer(Size(id: preset.name, name: preset.name, width: preset.width, height: preset.height))
        }
        return sizes
    }

    private func newRow(phone: Bool) -> some View {
        Group {
            if phone {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 10) { sizeTiles(width: 108) }
                }
            } else {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 116, maximum: 150), spacing: 10)], alignment: .leading, spacing: 10) {
                    sizeTiles(width: nil)
                }
            }
        }
    }

    @ViewBuilder
    private func sizeTiles(width: CGFloat?) -> some View {
        ForEach(sizes) { size in
            Button { actions.newCanvas(CGSize(width: size.width, height: size.height)) } label: {
                SizeTile(name: size.name, width: size.width, height: size.height, first: size.id == "last")
                    .frame(width: width)
            }
            .buttonStyle(.plain)
        }
        Button(action: actions.customCanvas) {
            SizeTile(name: "Custom…", width: 0, height: 0, first: false)
                .frame(width: width)
        }
        .buttonStyle(.plain)
    }

    /// A size as a tile: a swatch at its aspect, its name, its pixels.
    private struct SizeTile: View {
        let name: String
        let width: Int
        let height: Int
        let first: Bool

        var body: some View {
            VStack(spacing: 6) {
                ZStack {
                    if width > 0 {
                        let longest = CGFloat(max(width, height))
                        RoundedRectangle(cornerRadius: 2)
                            .fill(Color(white: 0.92))
                            .frame(width: 40 * CGFloat(width) / longest, height: 40 * CGFloat(height) / longest)
                    } else {
                        Image(systemName: "plus")
                            .font(.system(size: 20))
                            .foregroundColor(StartView.dim)
                    }
                }
                .frame(width: 44, height: 44)
                Text(name)
                    .font(.system(size: 12))
                    .lineLimit(1)
                Text(width > 0 ? "\(String(width)) × \(String(height))" : "width × height")
                    .font(.system(size: 11))
                    .foregroundColor(StartView.dim)
            }
            .padding(.vertical, 10)
            .padding(.horizontal, 6)
            .frame(maxWidth: .infinity)
            .background(RoundedRectangle(cornerRadius: 8).fill(Chrome.panel))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(first ? Color.accentColor.opacity(0.8) : Color.white.opacity(0.06)))
            .contentShape(RoundedRectangle(cornerRadius: 8))
        }
    }

    // MARK: - Recent

    private func recentGrid(phone: Bool) -> some View {
        Group {
            if recents.entries.isEmpty {
                Text("Your canvases will appear here.")
                    .font(.system(size: 13))
                    .foregroundColor(Self.dim)
                    .padding(.vertical, 6)
            } else {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: phone ? 140 : 168, maximum: 240), spacing: 14, alignment: .top)],
                          alignment: .leading, spacing: 18) {
                    ForEach(recents.entries) { entry in
                        Button { actions.open(entry) } label: {
                            RecentTile(entry: entry, recents: recents)
                        }
                        .buttonStyle(.plain)
                        .contextMenu {
                            if let reveal = actions.reveal {
                                Button(StartView.revealTitle) { reveal(entry) }
                            }
                            if actions.canRename(entry) {
                                Button("Rename…") {
                                    newName = entry.name
                                    renaming = entry
                                }
                            }
                            Button("Remove from Recents", role: .destructive) { recents.remove(entry) }
                        }
                    }
                }
            }
        }
    }

    static var revealTitle: String {
        #if os(macOS)
        return "Show in Finder"
        #else
        return "Show in Files"
        #endif
    }

    /// A canvas as a tile: its thumbnail, its name, its pixels and when it was last
    /// opened; dimmed, with a word, once it has gone.
    private struct RecentTile: View {
        let entry: RecentCanvases.Entry
        let recents: RecentCanvases
        @State private var image: CGImage?
        @State private var missing = false

        var body: some View {
            VStack(alignment: .leading, spacing: 6) {
                ZStack {
                    RoundedRectangle(cornerRadius: 6).fill(Chrome.panel)
                    if let image {
                        Image(decorative: image, scale: 1)
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                            .padding(4)
                    } else if missing {
                        Text("not found")
                            .font(.system(size: 12))
                            .foregroundColor(StartView.dim)
                    }
                }
                .frame(height: 112)
                .frame(maxWidth: .infinity)
                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color.white.opacity(0.08)))
                Text(entry.name)
                    .font(.system(size: 13))
                    .lineLimit(1)
                (Text("\(String(entry.width)) × \(String(entry.height)) · ") + Text(entry.openedAt, format: .relative(presentation: .named)))
                    .font(.system(size: 11))
                    .foregroundColor(StartView.dim)
                    .lineLimit(1)
            }
            .opacity(missing ? 0.45 : 1)
            .contentShape(Rectangle())
            .task(id: entry.path) {
                let recents = recents
                let loaded = await Task.detached(priority: .utility) { recents.thumbnail(of: entry) }.value
                image = loaded
                missing = loaded == nil && recents.url(of: entry) == nil
            }
        }
    }
}
