import SwiftUI
import ArtsyEngine

/// What the start screen can do, as each app does it: the Mac in windows and panels,
/// iPad and iPhone in screens and sheets over it.
struct StartActions {
    /// A canvas of this size, now.
    var newCanvas: (CGSize) -> Void = { _ in }
    /// A canvas of the screen's pixels as the screen: the interface away, the canvas
    /// edge to edge, and on the Mac the window full screen.
    var fullScreen: (CGSize) -> Void = { _ in }
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

/// Where each app starts, and comes back to with nothing open. The canvas opened last is
/// the largest thing on the screen, with nothing drawn around it, its name beside it and
/// the way to pick it up again; the other canvases opened lately follow in a row at their
/// own aspect; the sizes a canvas can be made at are their own shapes, outlined, in a
/// row; and the way to a document elsewhere and a canvas from a photo. See
/// `docs/start-screen-plan.md`.
struct StartView: View {
    @ObservedObject var recents: RecentCanvases
    /// The largest side this device takes; sizes beyond it are not offered.
    let maxSide: Int
    /// The pixels of the screen the app is on, as it is held now, for the "Full screen"
    /// tile; nil when there is no screen to ask. Asked again whenever the screen draws,
    /// so a turn or a fold is followed.
    let screenPixels: () -> CGSize?
    let actions: StartActions
    @ObservedObject private var prefs = AppPreferences.shared
    @State private var renaming: RecentCanvases.Entry?
    @State private var newName = ""
    /// Goes up when the window moves to another screen, so the sizes are asked again.
    @State private var screenChanges = 0
    /// The thumbnail of the canvas opened last, the picture that leads the screen.
    @State private var latest = Thumbnail.loading

    init(recents: RecentCanvases, maxSide: Int = LayerStack.maxCanvasSide, screenPixels: @escaping () -> CGSize? = { nil },
         actions: StartActions) {
        self.recents = recents
        self.maxSide = maxSide
        self.screenPixels = screenPixels
        self.actions = actions
    }

    static let dim = Chrome.secondaryText
    /// Targets a finger's size rather than a pointer's.
    #if os(iOS)
    static let touch = true
    #else
    static let touch = false
    #endif
    /// A window at least this wide puts the name beside the picture rather than under it.
    static let wideWidth: CGFloat = 1000

    var body: some View {
        GeometryReader { geometry in
            let phone = geometry.size.width < Chrome.phoneWidth
            let wide = geometry.size.width >= Self.wideWidth
            let margin: CGFloat = phone ? 20 : 40
            let content = geometry.size.width - 2 * margin
            ScrollView {
                VStack(alignment: .leading, spacing: phone ? 24 : 28) {
                    HStack(alignment: .center, spacing: 16) {
                        BrandMark(size: 20)
                        if !phone {
                            Spacer(minLength: 0)
                            elsewhere
                        }
                    }
                    if let first = recents.entries.first {
                        latestBlock(first, content: content, height: geometry.size.height, wide: wide, phone: phone)
                    } else {
                        welcome
                    }
                    if recents.entries.count > 1 {
                        section("Recent") { recentRow(phone: phone) }
                    }
                    Rectangle()
                        .fill(Chrome.hairline)
                        .frame(height: 1)
                    section("New canvas") { sizesRow(phone: phone) }
                    if phone {
                        elsewhere
                            .padding(.top, 4)
                    }
                }
                .padding(margin)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .background(Chrome.background.ignoresSafeArea())
        .foregroundColor(Chrome.text)
        .task(id: latestKey) { await loadLatest() }
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

    /// A section's label, lowercase and tracked, over its content.
    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Self.label(title)
            content()
        }
    }

    static func label(_ text: String) -> some View {
        Text(text.lowercased())
            .font(Chrome.sectionFont)
            .tracking(Chrome.sectionTracking)
            .foregroundColor(dim)
    }

    // MARK: - The canvas opened last

    /// A thumbnail as it is being read, read, or not there to read.
    ///
    /// Holds the leading picture; the tiles after it read their own.
    private enum Thumbnail {
        case loading
        case image(CGImage)
        /// Nothing to show: `missing` when the document itself has gone.
        case none(missing: Bool)

        var image: CGImage? {
            if case .image(let image) = self { return image }
            return nil
        }

        var missing: Bool {
            if case .none(let missing) = self { return missing }
            return false
        }
    }

    /// Changes with the document and with a save while the screen is up (a save notes
    /// the document anew, with the time), so the thumbnail is read again for either.
    private var latestKey: String {
        guard let first = recents.entries.first else { return "" }
        return "\(first.path) \(first.openedAt.timeIntervalSinceReferenceDate)"
    }

    private func loadLatest() async {
        guard let entry = recents.entries.first else {
            latest = .none(missing: false)
            return
        }
        latest = .loading
        let recents = recents
        let loaded = await Task.detached(priority: .utility) { recents.thumbnail(of: entry) }.value
        if let loaded {
            latest = .image(loaded)
        } else {
            latest = .none(missing: recents.url(of: entry) == nil)
        }
    }

    /// The canvas opened last: its picture, large, at its own aspect, and beside it on a
    /// wide window, under it otherwise, the word, its name, its pixels and when, and the
    /// way to open it.
    private func latestBlock(_ entry: RecentCanvases.Entry, content: CGFloat, height: CGFloat, wide: Bool, phone: Bool) -> some View {
        let aspect = Self.aspect(of: entry)
        let pictureWidth = wide ? (content * 0.58).rounded() : content
        let tallest = max(180, (height * (wide ? 0.62 : 0.42)).rounded())
        let pictureHeight = min(pictureWidth / aspect, tallest).rounded()
        let width = (pictureHeight * aspect).rounded()
        return Group {
            if wide {
                HStack(alignment: .top, spacing: 40) {
                    latestPicture(entry, width: width, height: pictureHeight)
                    captions(entry, nameSize: 36)
                        .padding(.top, 4)
                }
            } else {
                VStack(alignment: .leading, spacing: 18) {
                    latestPicture(entry, width: width, height: pictureHeight)
                    captions(entry, nameSize: phone ? 26 : 30)
                }
            }
        }
    }

    private func captions(_ entry: RecentCanvases.Entry, nameSize: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Mark()
                Self.label("Continue")
            }
            Text(entry.name)
                .font(Chrome.futura(nameSize, bold: true))
                .lineLimit(2)
            (Text("\(String(entry.width)) × \(String(entry.height)) · ") + Text(entry.openedAt, format: .relative(presentation: .named)))
                .font(Chrome.futura(14))
                .foregroundColor(Self.dim)
                .lineLimit(1)
                // The date's words change as time passes; the line keeps its full width
                .fixedSize(horizontal: true, vertical: false)
            Button { actions.open(entry) } label: {
                Text("open")
                    .font(Chrome.futura(14, bold: true))
                    .foregroundColor(.white)
                    .frame(width: Self.touch ? 132 : 120, height: Self.touch ? Chrome.target : 40)
                    .background(Rectangle().fill(Chrome.accent))
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(.top, 10)
            .help("Open this canvas")
        }
    }

    /// The thumbnail at the canvas's aspect, whole, on a plate; a word when there is
    /// none to show. A tap opens the canvas.
    private func latestPicture(_ entry: RecentCanvases.Entry, width: CGFloat, height: CGFloat) -> some View {
        Button { actions.open(entry) } label: {
            ZStack {
                Rectangle().fill(Chrome.control)
                switch latest {
                case .image(let image):
                    Image(decorative: image, scale: 1)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                case .none(let missing):
                    Text(missing ? "not found" : "no preview")
                        .font(Chrome.futura(14))
                        .foregroundColor(Self.dim)
                case .loading:
                    EmptyView()
                }
            }
            .frame(width: width, height: height)
            .clipped()
            .opacity(latest.missing ? 0.45 : 1)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Open \(entry.name)")
        .contextMenu { recentMenu(entry) }
    }

    /// Width over height, from the pixels the list knows before any thumbnail is read.
    static func aspect(of entry: RecentCanvases.Entry) -> CGFloat {
        guard entry.width > 0, entry.height > 0 else { return 1 }
        return CGFloat(entry.width) / CGFloat(entry.height)
    }

    /// With nothing opened yet, a line in the picture's place.
    private var welcome: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Welcome")
                .font(Chrome.futura(30, bold: true))
            Text("Start with a size below, or open a drawing. Canvases you work on gather here.")
                .font(Chrome.futura(15))
                .lineSpacing(3)
                .foregroundColor(Self.dim)
        }
        .frame(maxWidth: 480, alignment: .leading)
        .padding(.top, 8)
    }

    // MARK: - Elsewhere

    /// The way to a document elsewhere, and to a canvas from a photo: words, in the grey.
    private var elsewhere: some View {
        HStack(spacing: Self.touch ? 28 : 24) {
            Button(action: actions.browse) {
                Text(Self.plain(actions.browseTitle))
            }
            .buttonStyle(StartWordStyle())
            if let photos = actions.fromPhotos, let file = actions.fromImageFile {
                Menu {
                    Button("Photos…", action: photos)
                    Button("Files…", action: file)
                } label: {
                    HStack(spacing: 7) {
                        Text("from a photo")
                        Image(systemName: "arrowtriangle.down.fill")
                            .font(.system(size: 8))
                    }
                }
                .buttonStyle(StartWordStyle())
                .menuIndicator(.hidden)
            } else if let one = actions.fromPhotos ?? actions.fromImageFile {
                Button(action: one) { Text("from a photo") }
                    .buttonStyle(StartWordStyle())
            }
        }
    }

    /// A title as a lowercase word, without its ellipsis.
    static func plain(_ title: String) -> String {
        title.replacingOccurrences(of: "…", with: "").lowercased()
    }

    /// A word that is a button: the grey, and the text colour while pressed.
    private struct StartWordStyle: ButtonStyle {
        func makeBody(configuration: Configuration) -> some View {
            configuration.label
                .font(Chrome.futura(StartView.touch ? 15 : 14))
                .foregroundColor(configuration.isPressed ? Chrome.text : StartView.dim)
                .frame(height: StartView.touch ? Chrome.target : 28)
                .contentShape(Rectangle())
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

    /// The sizes offered: the size used last; Full screen, this screen's pixels the way
    /// the device is held, when there is a screen to ask; then the presets. A size the
    /// device cannot take is left out (the last one too: a Huge canvas from before the
    /// cap would only fail again), and so is one that repeats an earlier tile. When the
    /// last canvas was the screen's, Full screen stands first in its place: it makes the
    /// same canvas and opens it as the screen.
    static func sizes(last: CGSize, screen: CGSize?, maxSide: Int) -> [Size] {
        var sizes: [Size] = []
        func offer(_ size: Size) {
            guard max(size.width, size.height) <= maxSide, size.width > 0, size.height > 0,
                  !sizes.contains(where: { $0.width == size.width && $0.height == size.height }) else { return }
            sizes.append(size)
        }
        let lastSize = Size(id: "last", name: "Same as last", width: Int(last.width), height: Int(last.height))
        let screenSize = screen.map { Size(id: "screen", name: "Full screen", width: Int($0.width.rounded()), height: Int($0.height.rounded())) }
        if let screenSize, screenSize.width == lastSize.width, screenSize.height == lastSize.height {
            offer(screenSize)
        } else {
            offer(lastSize)
            if let screenSize { offer(screenSize) }
        }
        for preset in CanvasSizePreset.presets {
            offer(Size(id: preset.name, name: preset.name, width: preset.width, height: preset.height))
        }
        return sizes
    }

    /// The sizes as cells in rows that wrap, each its own shape with its name and pixels
    /// under it.
    private func sizesRow(phone: Bool) -> some View {
        let sizes = sizes
        return FlowLayout(spacing: phone ? 14 : 16, rowSpacing: 22) {
            ForEach(sizes) { size in
                let pixels = CGSize(width: size.width, height: size.height)
                Button { size.id == "screen" ? actions.fullScreen(pixels) : actions.newCanvas(pixels) } label: {
                    SizeCell(name: size.name, width: size.width, height: size.height, first: size == sizes.first, isScreen: size.id == "screen")
                }
                .buttonStyle(.plain)
            }
            Button(action: actions.customCanvas) {
                SizeCell(name: "Custom", width: 0, height: 0, first: false, isScreen: false)
            }
            .buttonStyle(.plain)
        }
    }

    /// A size as a cell: its shape at its aspect and, between sizes, roughly its scale,
    /// over its name and its pixels. The first is filled in the one colour; the rest are
    /// outlined. The screen's carries the full-screen arrows, since its canvas opens as
    /// the screen; Custom a plus.
    private struct SizeCell: View {
        let name: String
        let width: Int
        let height: Int
        let first: Bool
        let isScreen: Bool

        private var custom: Bool { width == 0 }
        static let cellWidth: CGFloat = StartView.touch ? 118 : 108

        var body: some View {
            VStack(alignment: .leading, spacing: 8) {
                glyph
                    .frame(height: 28, alignment: .bottomLeading)
                Text(name)
                    .font(Chrome.futura(14, bold: first))
                    .foregroundColor(Chrome.text)
                    .lineLimit(1)
                Text(width > 0 ? "\(String(width)) × \(String(height))" : "width × height")
                    .font(Chrome.futura(12))
                    .foregroundColor(StartView.dim)
                    .lineLimit(1)
                    .padding(.top, -4)
            }
            .frame(width: Self.cellWidth, alignment: .leading)
            .contentShape(Rectangle())
        }

        @ViewBuilder
        private var glyph: some View {
            if isScreen {
                Image(systemName: "arrow.up.left.and.arrow.down.right")
                    .font(.system(size: 18, weight: .regular))
                    .foregroundColor(Chrome.text)
                    .frame(width: 28, height: 28)
            } else if custom {
                Image(systemName: "plus")
                    .font(.system(size: 20, weight: .regular))
                    .foregroundColor(Chrome.text)
                    .frame(width: 28, height: 28)
            } else {
                // Between sizes a cue, not a scale: the square root keeps Small readable
                // beside Huge
                let longest = CGFloat(max(width, height))
                let side = 28 * (0.55 + 0.45 * sqrt(longest / 8192))
                let size = CGSize(width: (side * CGFloat(width) / longest).rounded(), height: (side * CGFloat(height) / longest).rounded())
                if first {
                    Rectangle()
                        .fill(Chrome.accent)
                        .frame(width: size.width, height: size.height)
                } else {
                    Rectangle()
                        .strokeBorder(Chrome.text, lineWidth: 1.5)
                        .frame(width: size.width, height: size.height)
                }
            }
        }
    }

    // MARK: - Recent

    /// The canvases after the one that leads, as tiles at their own aspect that wrap.
    private func recentRow(phone: Bool) -> some View {
        FlowLayout(spacing: phone ? 16 : 24, rowSpacing: 22) {
            ForEach(recents.entries.dropFirst()) { entry in
                Button { actions.open(entry) } label: {
                    RecentTile(entry: entry, recents: recents, height: Self.touch && !phone ? 112 : 96)
                }
                .buttonStyle(.plain)
                .contextMenu { recentMenu(entry) }
            }
        }
    }

    @ViewBuilder
    private func recentMenu(_ entry: RecentCanvases.Entry) -> some View {
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

    static var revealTitle: String {
        #if os(macOS)
        return "Show in Finder"
        #else
        return "Show in Files"
        #endif
    }

    /// A canvas as a tile: its thumbnail at the canvas's aspect, its name, its pixels
    /// and when it was last opened; dimmed, with a word, once it has gone; a word too
    /// for a document that is there but keeps no thumbnail that can be read.
    private struct RecentTile: View {
        let entry: RecentCanvases.Entry
        let recents: RecentCanvases
        let height: CGFloat
        @State private var image: CGImage?
        @State private var missing = false
        @State private var looked = false

        var body: some View {
            let width = min(max(height * StartView.aspect(of: entry), 48), 220)
            VStack(alignment: .leading, spacing: 10) {
                ZStack {
                    Rectangle().fill(Chrome.control)
                    if let image {
                        Image(decorative: image, scale: 1)
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                    } else if missing || looked {
                        Text(missing ? "not found" : "no preview")
                            .font(Chrome.futura(12))
                            .foregroundColor(StartView.dim)
                    }
                }
                .frame(width: width, height: height)
                .clipped()
                Text(entry.name)
                    .font(Chrome.futura(14))
                    .lineLimit(1)
                (Text("\(String(entry.width)) × \(String(entry.height)) · ") + Text(entry.openedAt, format: .relative(presentation: .named)))
                    .font(Chrome.futura(12))
                    .foregroundColor(StartView.dim)
                    .lineLimit(1)
                    .padding(.top, -5)
            }
            // Room for the pixels and the date on one line under a narrow thumbnail
            .frame(width: max(width, 150), alignment: .leading)
            .opacity(missing ? 0.45 : 1)
            .contentShape(Rectangle())
            // Read again when the document is saved while the screen is up (a save notes
            // it anew, with the time), not only when the entry is another document's
            .task(id: "\(entry.path) \(entry.openedAt.timeIntervalSinceReferenceDate)") {
                let recents = recents
                let loaded = await Task.detached(priority: .utility) { recents.thumbnail(of: entry) }.value
                image = loaded
                missing = loaded == nil && recents.url(of: entry) == nil
                looked = true
            }
        }
    }
}

/// Rows of views that wrap at the width given, each row as tall as its tallest view.
struct FlowLayout: Layout {
    var spacing: CGFloat = 8
    var rowSpacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = rows(of: subviews, within: proposal.width ?? .infinity)
        let width = proposal.width ?? rows.map(\.width).max() ?? 0
        let height = rows.reduce(0) { $0 + $1.height } + CGFloat(max(rows.count - 1, 0)) * rowSpacing
        return CGSize(width: width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for row in rows(of: subviews, within: bounds.width) {
            var x = bounds.minX
            for index in row.indices {
                let size = subviews[index].sizeThatFits(.unspecified)
                subviews[index].place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
                x += size.width + spacing
            }
            y += row.height + rowSpacing
        }
    }

    private struct Row {
        var indices: [Int] = []
        var width: CGFloat = 0
        var height: CGFloat = 0
    }

    private func rows(of subviews: Subviews, within width: CGFloat) -> [Row] {
        var rows: [Row] = []
        var row = Row()
        for (index, subview) in subviews.enumerated() {
            let size = subview.sizeThatFits(.unspecified)
            if !row.indices.isEmpty, row.width + spacing + size.width > width {
                rows.append(row)
                row = Row()
            }
            row.width += (row.indices.isEmpty ? 0 : spacing) + size.width
            row.height = max(row.height, size.height)
            row.indices.append(index)
        }
        if !row.indices.isEmpty { rows.append(row) }
        return rows
    }
}
