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

/// Where each app starts, and comes back to with nothing open. The canvas opened last
/// fills the screen as a blurred backdrop and stands first as a Continue card; a row of
/// size pills makes a canvas in one tap; the other canvases opened lately follow as
/// thumbnails at their own aspect; and the way to a document elsewhere and a canvas
/// from a photo. See `docs/start-screen-plan.md`.
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
    /// The thumbnail of the canvas opened last: the Continue card's picture and, blurred,
    /// the backdrop behind everything.
    @State private var latest = Thumbnail.loading

    init(recents: RecentCanvases, maxSide: Int = LayerStack.maxCanvasSide, screenPixels: @escaping () -> CGSize? = { nil },
         actions: StartActions) {
        self.recents = recents
        self.maxSide = maxSide
        self.screenPixels = screenPixels
        self.actions = actions
    }

    /// The ground the backdrop fades into.
    static let ground = Color(white: 0.08)
    static let dim = Chrome.text.opacity(0.7)
    /// Targets a finger's size rather than a pointer's.
    #if os(iOS)
    static let touch = true
    #else
    static let touch = false
    #endif

    var body: some View {
        GeometryReader { geometry in
            let phone = geometry.size.width < Chrome.phoneWidth
            ScrollView {
                VStack(alignment: .leading, spacing: phone ? 22 : 24) {
                    #if os(iOS)
                    HStack(alignment: .center, spacing: 16) {
                        Text("Artsy")
                            .font(.system(size: 22, weight: .semibold))
                        if !phone {
                            Spacer(minLength: 0)
                            elsewhere
                        }
                    }
                    .padding(.top, 4)
                    #endif
                    if let first = recents.entries.first {
                        if phone {
                            continueCard(first, phone: true)
                        } else {
                            HStack(alignment: .top, spacing: 24) {
                                continueCard(first, phone: false)
                                #if os(macOS)
                                Spacer(minLength: 0)
                                elsewhere
                                #endif
                            }
                        }
                    } else {
                        HStack(alignment: .top, spacing: 24) {
                            welcome
                            #if os(macOS)
                            if !phone {
                                Spacer(minLength: 0)
                                elsewhere
                            }
                            #endif
                        }
                    }
                    section("New canvas") { newRow(phone: phone) }
                    if recents.entries.count != 1 {
                        section("Recent") { recentFlow(phone: phone) }
                    }
                    if phone {
                        elsewhere
                            .padding(.top, 6)
                    }
                }
                .padding(phone ? 16 : 28)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .background(Backdrop(image: latest.image).ignoresSafeArea())
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

    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title)
                .font(.system(size: 12, weight: .medium))
                .textCase(.uppercase)
                .tracking(0.6)
                .foregroundColor(Self.dim)
            content()
        }
    }

    // MARK: - The canvas opened last

    /// A thumbnail as it is being read, read, or not there to read.
    ///
    /// Holds the Continue card's picture; the tiles after it read their own.
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

    /// The canvas opened last as a card to pick it up again: its picture, its name, its
    /// pixels and when, and an Open pill. On a phone the picture sits across the card.
    private func continueCard(_ entry: RecentCanvases.Entry, phone: Bool) -> some View {
        Button { actions.open(entry) } label: {
            Group {
                if phone {
                    VStack(alignment: .leading, spacing: 10) {
                        latestPicture(entry, height: 180, across: true)
                        HStack(alignment: .center, spacing: 12) {
                            captions(entry, nameSize: 18)
                            Spacer(minLength: 0)
                            openPill
                        }
                        .padding(.horizontal, 4)
                        .padding(.bottom, 2)
                    }
                } else {
                    HStack(spacing: 22) {
                        latestPicture(entry, height: 156, across: false)
                        VStack(alignment: .leading, spacing: 6) {
                            captions(entry, nameSize: 24)
                            openPill
                                .padding(.top, 10)
                        }
                        .padding(.trailing, 14)
                    }
                }
            }
            .padding(12)
            .background(RoundedRectangle(cornerRadius: 14).fill(Color(white: 0.11).opacity(0.62)))
            .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(Color.white.opacity(0.12)))
            .shadow(color: .black.opacity(0.35), radius: 20, y: 10)
            .opacity(latest.missing ? 0.45 : 1)
            .contentShape(RoundedRectangle(cornerRadius: 14))
        }
        .buttonStyle(.plain)
        .contextMenu { recentMenu(entry) }
    }

    private func captions(_ entry: RecentCanvases.Entry, nameSize: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text("Continue")
                .font(.system(size: 11))
                .textCase(.uppercase)
                .tracking(1)
                .foregroundColor(Self.dim)
            Text(entry.name)
                .font(.system(size: nameSize, weight: .semibold))
                .lineLimit(1)
            (Text("\(String(entry.width)) × \(String(entry.height)) · ") + Text(entry.openedAt, format: .relative(presentation: .named)))
                .font(.system(size: 12))
                .foregroundColor(Chrome.text.opacity(0.8))
                .lineLimit(1)
                // The date's words change as time passes; the line keeps its full width
                .fixedSize(horizontal: true, vertical: false)
        }
    }

    private var openPill: some View {
        Text("Open")
            .font(.system(size: Self.touch ? 14 : 12, weight: .semibold))
            .foregroundColor(.white)
            .padding(.horizontal, Self.touch ? 18 : 16)
            .frame(height: Self.touch ? 36 : 30)
            .background(Capsule().fill(Color.accentColor))
    }

    /// The thumbnail at the card's height and the canvas's aspect, or `across` the width
    /// given, whole, on a plate; a word when there is none to show.
    private func latestPicture(_ entry: RecentCanvases.Entry, height: CGFloat, across: Bool) -> some View {
        ZStack {
            RoundedRectangle(cornerRadius: 7).fill(Color.white.opacity(0.08))
            switch latest {
            case .image(let image):
                Image(decorative: image, scale: 1)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .padding(across ? 6 : 0)
            case .none(let missing):
                Text(missing ? "not found" : "no preview")
                    .font(.system(size: 12))
                    .foregroundColor(Self.dim)
            case .loading:
                EmptyView()
            }
        }
        .frame(width: across ? nil : min(max(height * Self.aspect(of: entry), 72), 280), height: height)
        .frame(maxWidth: across ? .infinity : nil)
        .clipShape(RoundedRectangle(cornerRadius: 7))
        .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(Color.white.opacity(0.08)))
        .shadow(color: .black.opacity(0.5), radius: 15, y: 10)
    }

    /// Width over height, from the pixels the list knows before any thumbnail is read.
    static func aspect(of entry: RecentCanvases.Entry) -> CGFloat {
        guard entry.width > 0, entry.height > 0 else { return 1 }
        return CGFloat(entry.width) / CGFloat(entry.height)
    }

    /// With nothing opened yet, a word in the card's place.
    private var welcome: some View {
        VStack(alignment: .leading, spacing: 8) {
            #if os(macOS)
            Text("Welcome to Artsy")
                .font(.system(size: 26, weight: .semibold))
            #endif
            Text("Start with a size below, or open a drawing. Canvases you work on will gather here.")
                .font(.system(size: 13))
                .lineSpacing(3)
                .foregroundColor(Chrome.text.opacity(0.8))
        }
        .frame(maxWidth: 460, alignment: .leading)
        .padding(.top, 8)
    }

    // MARK: - Elsewhere

    /// The way to a document elsewhere, and to a canvas from a photo.
    private var elsewhere: some View {
        HStack(spacing: 8) {
            Button(actions.browseTitle, action: actions.browse)
                .buttonStyle(StartButtonStyle())
            if let photos = actions.fromPhotos, let file = actions.fromImageFile {
                Menu {
                    Button("Photos…", action: photos)
                    Button("Files…", action: file)
                } label: {
                    HStack(spacing: 6) {
                        Text("From a photo…")
                        Image(systemName: "chevron.down")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundColor(Self.dim)
                    }
                }
                .buttonStyle(StartButtonStyle())
            } else if let one = actions.fromPhotos ?? actions.fromImageFile {
                Button("From a photo…", action: one)
                    .buttonStyle(StartButtonStyle())
            }
        }
    }

    /// A translucent button over the backdrop; a finger's height on iPad and iPhone.
    private struct StartButtonStyle: ButtonStyle {
        func makeBody(configuration: Configuration) -> some View {
            let radius: CGFloat = StartView.touch ? 10 : 6
            configuration.label
                .font(.system(size: StartView.touch ? 15 : 12))
                .padding(.horizontal, StartView.touch ? 16 : 13)
                .frame(height: StartView.touch ? Chrome.target : 28)
                .background(RoundedRectangle(cornerRadius: radius).fill(Color.white.opacity(configuration.isPressed ? 0.2 : 0.1)))
                .overlay(RoundedRectangle(cornerRadius: radius).strokeBorder(Color.white.opacity(0.16)))
                .contentShape(RoundedRectangle(cornerRadius: radius))
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

    /// The pills in rows that wrap; on a phone one row that scrolls sideways.
    private func newRow(phone: Bool) -> some View {
        Group {
            if phone {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) { sizePills }
                }
            } else {
                FlowLayout(spacing: 8, rowSpacing: 8) { sizePills }
            }
        }
    }

    @ViewBuilder
    private var sizePills: some View {
        let sizes = sizes
        ForEach(sizes) { size in
            let pixels = CGSize(width: size.width, height: size.height)
            Button { size.id == "screen" ? actions.fullScreen(pixels) : actions.newCanvas(pixels) } label: {
                SizePill(name: size.name, width: size.width, height: size.height, first: size == sizes.first, isScreen: size.id == "screen")
            }
            .buttonStyle(.plain)
        }
        Button(action: actions.customCanvas) {
            SizePill(name: "Custom…", width: 0, height: 0, first: false, isScreen: false)
        }
        .buttonStyle(.plain)
    }

    /// A size as a pill: a glyph at its aspect and, between sizes, roughly its scale,
    /// its name, its pixels. The first stands in the accent. The screen's carries the
    /// full-screen arrows, since its canvas opens as the screen; Custom a plus.
    private struct SizePill: View {
        let name: String
        let width: Int
        let height: Int
        let first: Bool
        let isScreen: Bool

        private var custom: Bool { width == 0 }

        var body: some View {
            let touch = StartView.touch
            HStack(spacing: touch ? 8 : 7) {
                glyph
                    .frame(width: touch ? 18 : 16, height: touch ? 18 : 16)
                Text(name)
                    .font(.system(size: touch ? 14 : 12, weight: first ? .semibold : .regular))
                    .lineLimit(1)
                Text(width > 0 ? "\(String(width)) × \(String(height))" : "width × height")
                    .font(.system(size: touch ? 12 : 11))
                    .foregroundColor(first ? Color.white.opacity(0.75) : StartView.dim)
                    .lineLimit(1)
            }
            .padding(.leading, touch ? 13 : 10)
            .padding(.trailing, touch ? 16 : 12)
            .frame(height: touch ? Chrome.target : 32)
            .foregroundColor(first ? .white : Chrome.text)
            .background(Capsule().fill(first ? Color.accentColor : (custom ? Color.clear : Color.white.opacity(0.09))))
            .overlay(Capsule().strokeBorder(first ? Color.clear : Color.white.opacity(custom ? 0.28 : 0.14)))
            .contentShape(Capsule())
        }

        @ViewBuilder
        private var glyph: some View {
            if isScreen {
                Image(systemName: "arrow.up.left.and.arrow.down.right")
                    .font(.system(size: StartView.touch ? 13 : 12, weight: .semibold))
            } else if custom {
                Image(systemName: "plus")
                    .font(.system(size: StartView.touch ? 14 : 13, weight: .semibold))
                    .foregroundColor(Color(white: 0.85))
            } else {
                // Between sizes a cue, not a scale: the square root keeps Small readable
                // beside Huge
                let longest = CGFloat(max(width, height))
                let side = (StartView.touch ? 18 : 16) * (0.55 + 0.45 * sqrt(longest / 8192))
                RoundedRectangle(cornerRadius: 1)
                    .fill(first ? Color.white.opacity(0.9) : Color(white: 0.92))
                    .frame(width: side * CGFloat(width) / longest, height: side * CGFloat(height) / longest)
            }
        }
    }

    // MARK: - Recent

    /// The canvases after the one on the card, as thumbnails at their own aspect that
    /// wrap; with nothing in the list, a word.
    private func recentFlow(phone: Bool) -> some View {
        Group {
            if recents.entries.isEmpty {
                Text("Your canvases will appear here.")
                    .font(.system(size: 13))
                    .foregroundColor(Self.dim)
                    .padding(.vertical, 6)
            } else {
                FlowLayout(spacing: 16, rowSpacing: 18) {
                    ForEach(recents.entries.dropFirst()) { entry in
                        Button { actions.open(entry) } label: {
                            RecentTile(entry: entry, recents: recents, height: Self.touch && !phone ? 120 : 96)
                        }
                        .buttonStyle(.plain)
                        .contextMenu { recentMenu(entry) }
                    }
                }
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
            VStack(alignment: .leading, spacing: 8) {
                ZStack {
                    RoundedRectangle(cornerRadius: 4).fill(Color.white.opacity(0.08))
                    if let image {
                        Image(decorative: image, scale: 1)
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                    } else if missing || looked {
                        Text(missing ? "not found" : "no preview")
                            .font(.system(size: 11))
                            .foregroundColor(StartView.dim)
                    }
                }
                .frame(width: width, height: height)
                .clipShape(RoundedRectangle(cornerRadius: 4))
                .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(Color.white.opacity(0.1)))
                .shadow(color: .black.opacity(image == nil ? 0 : 0.5), radius: 11, y: 8)
                Text(entry.name)
                    .font(.system(size: 12, weight: .medium))
                    .lineLimit(1)
                (Text("\(String(entry.width)) × \(String(entry.height)) · ") + Text(entry.openedAt, format: .relative(presentation: .named)))
                    .font(.system(size: 11))
                    .foregroundColor(StartView.dim)
                    .lineLimit(1)
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

    // MARK: - The backdrop

    /// The canvas opened last, blurred and dimmed, under a scrim that fades to the
    /// ground; with no canvas to show, a few strokes in its place.
    private struct Backdrop: View {
        let image: CGImage?

        var body: some View {
            GeometryReader { geometry in
                let size = geometry.size
                ZStack {
                    StartView.ground
                    if let image {
                        Image(decorative: image, scale: 1)
                            .resizable()
                            .aspectRatio(contentMode: .fill)
                            .frame(width: size.width, height: size.height)
                            .scaleEffect(1.15)
                            .saturation(1.2)
                            .blur(radius: 36)
                            .opacity(0.45)
                    } else {
                        Strokes()
                            .frame(width: size.width, height: size.height)
                            .blur(radius: 22)
                            .opacity(0.32)
                    }
                    LinearGradient(stops: [
                        .init(color: StartView.ground.opacity(0.12), location: 0),
                        .init(color: StartView.ground.opacity(0.7), location: 0.5),
                        .init(color: StartView.ground.opacity(0.97), location: 1),
                    ], startPoint: .top, endPoint: .bottom)
                }
                .frame(width: size.width, height: size.height)
                .clipped()
            }
        }
    }

    /// Three loose strokes, as the first launch's backdrop.
    private struct Strokes: View {
        var body: some View {
            Canvas { context, size in
                let w = size.width, h = size.height
                var sweep = Path()
                sweep.move(to: CGPoint(x: -0.05 * w, y: 0.8 * h))
                sweep.addCurve(to: CGPoint(x: 0.6 * w, y: 0.65 * h), control1: CGPoint(x: 0.18 * w, y: 0.45 * h), control2: CGPoint(x: 0.43 * w, y: 0.55 * h))
                sweep.addCurve(to: CGPoint(x: 1.07 * w, y: 0.25 * h), control1: CGPoint(x: 0.77 * w, y: 0.75 * h), control2: CGPoint(x: 0.93 * w, y: 0.58 * h))
                context.stroke(sweep, with: .color(Color(red: 0.91, green: 0.45, blue: 0.23)), style: StrokeStyle(lineWidth: 0.14 * h, lineCap: .round))
                var arc = Path()
                arc.move(to: CGPoint(x: 0.07 * w, y: 0.18 * h))
                arc.addCurve(to: CGPoint(x: 0.86 * w, y: 0.3 * h), control1: CGPoint(x: 0.3 * w, y: 0.34 * h), control2: CGPoint(x: 0.55 * w, y: 0.09 * h))
                context.stroke(arc, with: .color(Color(red: 0.18, green: 0.44, blue: 0.84).opacity(0.8)), style: StrokeStyle(lineWidth: 0.06 * h, lineCap: .round))
                let sun = Path(ellipseIn: CGRect(x: 0.72 * w, y: 0.76 * h, width: 0.16 * w, height: 0.16 * w))
                context.fill(sun, with: .color(Color(red: 0.95, green: 0.79, blue: 0.3).opacity(0.8)))
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
