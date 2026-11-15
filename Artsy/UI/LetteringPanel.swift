import SwiftUI
import ArtsyEngine

/// How a picked-up balloon is marked over the canvas, on the Mac and on iPad alike: a
/// dashed box and handles in the accent.
enum BalloonSelectionStyle {
    static let colour = CGColor(srgbRed: 0.878, green: 0.227, blue: 0.184, alpha: 1)
    static let dash: [CGFloat] = [4, 3]
    /// The handles' radius, in points.
    static let handleRadius: CGFloat = 5
}

/// The Letter tool's panel, over the canvas's top-right corner while the tool is in use:
/// the style and its look, and for the picked-up balloon its words, face, size, capitals
/// and tail. With no balloon picked up, the style, look, face and capitals are the next one's.
struct LetteringPanel: View {
    @ObservedObject var viewModel: CanvasViewModel
    let actions: ChromeActions
    @ObservedObject private var fonts = DrawnFontLibrary.shared
    @FocusState private var typing: Bool
    @Environment(\.displayScale) private var displayScale

    static let width: CGFloat = 300

    var body: some View {
        if viewModel.currentTool == .letter, !viewModel.isChromeHidden {
            panel
        }
    }

    private var panel: some View {
        let balloon = viewModel.selectedBalloon
        let style = balloon?.style ?? viewModel.balloonStyle
        return VStack(alignment: .leading, spacing: 10) {
            Text("lettering")
                .font(Chrome.futura(15, bold: true))
                .foregroundColor(Chrome.text)
            HStack(spacing: 4) {
                ForEach(BalloonStyle.allCases) { kind in
                    SquareChoice(systemImage: kind.systemImage, text: kind.rawValue, isSelected: style == kind,
                                 height: 46, font: Chrome.labelFont, help: "\(kind.rawValue.capitalized) balloon") {
                        viewModel.restyleSelectedBalloon(kind, renderer: actions.renderer())
                    }
                }
            }
            if style != .sound {
                lookRows(style: style, look: balloon?.look ?? viewModel.balloonLook(for: style))
            }
            if let balloon {
                editor(for: balloon)
            } else {
                // The next balloon's face, or a drawn font over it
                let drawn = fonts.font(id: viewModel.balloonDrawnFont)?.id
                HStack(spacing: 4) {
                    ForEach(LetteringFace.allCases) { face in
                        SquareChoice(text: face.rawValue, isSelected: drawn == nil && viewModel.balloonFace == face, height: 30,
                                     font: Chrome.labelFont, help: "Letter in the \(face.rawValue) face") {
                            viewModel.balloonFace = face
                            viewModel.balloonDrawnFont = nil
                        }
                    }
                }
                drawnFonts(selected: drawn) { id in viewModel.balloonDrawnFont = id }
                Text("Tap the page to place a balloon; tap one to change it.")
                    .font(Chrome.labelFont)
                    .foregroundColor(Chrome.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(14)
        .frame(width: Self.width)
        .background(Chrome.panel)
        .overlay(Rectangle().strokeBorder(Chrome.hairline))
    }

    @ViewBuilder
    private func editor(for balloon: Balloon) -> some View {
        ZStack(alignment: .topLeading) {
            TextEditor(text: Binding(get: { viewModel.selectedBalloon?.text ?? "" },
                                     set: { words in change("Edit Words") { $0.text = words } }))
                .font(.system(size: 15))
                .scrollContentBackground(.hidden)
                .focused($typing)
                .padding(6)
                .task(id: viewModel.balloonWantsKeyboard) {
                    // A balloon just placed: the keyboard to its words, once the text box,
                    // which appears with it, is in its window
                    guard viewModel.balloonWantsKeyboard else { return }
                    try? await Task.sleep(for: .milliseconds(150))
                    typing = true
                    viewModel.balloonWantsKeyboard = false
                }
            if balloon.text.isEmpty {
                Text("the words")
                    .font(.system(size: 15))
                    .foregroundColor(Chrome.secondaryText)
                    .padding(.horizontal, 11)
                    .padding(.vertical, 14)
                    .allowsHitTesting(false)
            }
        }
        .frame(height: 92)
        .background(Chrome.control)
        .overlay(Rectangle().strokeBorder(Chrome.hairline))

        let drawn = fonts.font(id: balloon.drawnFont)?.id
        HStack(spacing: 4) {
            ForEach(LetteringFace.allCases) { face in
                SquareChoice(text: face.rawValue, isSelected: drawn == nil && balloon.face == face, height: 30, font: Chrome.labelFont,
                             help: "Letter in the \(face.rawValue) face") {
                    viewModel.balloonFace = face
                    viewModel.balloonDrawnFont = nil
                    change("Lettering Face") { $0.face = face; $0.drawnFont = nil }
                }
            }
        }
        drawnFonts(selected: drawn) { id in
            viewModel.balloonDrawnFont = id
            change("Lettering Face") { $0.drawnFont = id }
        }
        HStack(spacing: 6) {
            Text("size")
                .font(Chrome.labelFont)
                .foregroundColor(Chrome.secondaryText)
            ChromeButton(systemImage: "minus", size: 30, help: "Smaller words") {
                change("Lettering Size") { $0.fontSize = max(6, ($0.fontSize / 1.1).rounded()) }
            }
            Text("\(Int(balloon.fontSize))")
                .font(Chrome.valueFont)
                .foregroundColor(Chrome.text)
                .frame(minWidth: 30)
            ChromeButton(systemImage: "plus", size: 30, help: "Larger words") {
                change("Lettering Size") { $0.fontSize = min(2000, ($0.fontSize * 1.1).rounded()) }
            }
            Spacer(minLength: 4)
            SquareChoice(text: "caps", isSelected: balloon.allCaps, height: 30, font: Chrome.labelFont, help: "All capitals") {
                viewModel.balloonCaps = !balloon.allCaps
                change("Capitals") { $0.allCaps.toggle() }
            }
            .frame(width: 52)
            if balloon.style.hasTail {
                SquareChoice(text: "tail", isSelected: balloon.tail != nil, height: 30, font: Chrome.labelFont, help: "A tail to the speaker") {
                    change("Balloon Tail") { b in
                        b.tail = b.tail == nil ? Balloon.new(b.style, at: b.center, face: b.face, fontSize: b.fontSize, allCaps: b.allCaps).tail : nil
                    }
                }
                .frame(width: 52)
            }
        }
        HStack(spacing: 6) {
            SquareChoice(text: "bold", isSelected: balloon.bold, height: 30, font: Chrome.futura(12, bold: true),
                         help: "The words in bold") {
                change("Bold") { $0.bold.toggle() }
            }
            .frame(width: 56)
            SquareChoice(text: "italic", isSelected: balloon.italic, height: 30, font: Chrome.labelFont.italic(),
                         help: "The words in italic") {
                change("Italic") { $0.italic.toggle() }
            }
            .frame(width: 56)
            Text(verbatim: "*word* stresses it")
                .font(Chrome.labelFont)
                .foregroundColor(Chrome.secondaryText)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
                .help("Words between asterisks are set in bold italic, as comics stress a word")
            Spacer(minLength: 0)
        }
        Button {
            guard let renderer = actions.renderer() else { return }
            viewModel.deleteSelectedBalloon(renderer: renderer)
        } label: {
            Text("delete balloon")
                .font(Chrome.labelFont)
                .foregroundColor(Chrome.accent)
                .frame(maxWidth: .infinity, minHeight: 30)
                .overlay(Rectangle().strokeBorder(Chrome.hairline))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Take this balloon off the page (Delete)")
    }

    /// The artist's drawn fonts, each named in itself, and the way into the Font Studio.
    private func drawnFonts(selected: UUID?, choose: @escaping (UUID) -> Void) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 4) {
                ForEach(fonts.fonts) { font in
                    SquareChoice(text: font.name, isSelected: selected == font.id, height: 30,
                                 font: DrawnFonts.font(id: font.id, size: 15, fallback: GlyphSheetDrawing.markFace).map { Font($0) }
                                    ?? Chrome.labelFont,
                                 help: "Letter in \(font.name), drawn in the Font Studio") {
                        choose(font.id)
                    }
                    .frame(minWidth: 64)
                    .fixedSize(horizontal: true, vertical: false)
                    .padding(.horizontal, 2)
                }
                Button {
                    actions.app("showFontStudio")
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: "pencil.and.outline")
                        Text(fonts.fonts.isEmpty ? "draw a font" : "font studio")
                    }
                    .font(Chrome.labelFont)
                    .foregroundColor(Chrome.secondaryText)
                    .padding(.horizontal, 8)
                    .frame(height: 30)
                    .overlay(Rectangle().strokeBorder(Chrome.hairline))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Draw your own lettering fonts (⇧⌘L)")
            }
            .id(fonts.revision)
        }
    }

    // MARK: - The look

    /// The balloon's look, a row each for its shape, line, fill and tail, every choice a
    /// picture of the balloon as it would be.
    @ViewBuilder
    private func lookRows(style: BalloonStyle, look: BalloonLook) -> some View {
        let shape = look.shape.flatMap { style.shapes.contains($0) ? $0 : nil } ?? style.shapes.first
        lookRow("shape") {
            ForEach(style.shapes) { choice in
                let changed = look.with { $0.shape = choice }
                LookChoice(isSelected: shape == choice, help: "\(choice.rawValue.capitalized) \(style.rawValue)",
                           action: { editLook("Balloon Shape") { $0.shape = choice } }) {
                    preview(style, changed, tail: false, size: Self.wideTile)
                }
            }
        }
        lookRow("line") {
            ForEach(BalloonLine.allCases) { choice in
                let changed = look.with { $0.line = choice }
                LookChoice(isSelected: look.line == choice, help: Self.help(for: choice),
                           action: { editLook("Balloon Line") { $0.line = choice } }) {
                    preview(style, changed, tail: false, size: Self.narrowTile)
                }
            }
        }
        lookRow("fill") {
            ForEach(BalloonFill.allCases) { choice in
                LookChoice(isSelected: look.fill == choice, dims: false,
                           help: choice == .black ? "Filled black, the words white" : "Filled \(choice.rawValue)",
                           action: { editLook("Balloon Fill") { $0.fill = choice } }) {
                    RoundedRectangle(cornerRadius: 3)
                        .fill(Color(cgColor: choice.color))
                        .overlay(RoundedRectangle(cornerRadius: 3).strokeBorder(Chrome.hairline))
                        .frame(width: 24, height: 16)
                }
            }
        }
        if style.hasTail {
            let tail = look.tail ?? style.ownTail
            lookRow("tail") {
                ForEach(BalloonTail.allCases) { choice in
                    let changed = look.with { $0.tail = choice }
                    LookChoice(isSelected: tail == choice, help: Self.help(for: choice),
                               action: { editLook("Tail Shape", addingTail: true) { $0.tail = choice } }) {
                        preview(style, changed, tail: true, size: Self.wideTile)
                    }
                }
            }
            lookRow("width") {
                ChromeButton(systemImage: "minus", size: 30, help: "A narrower tail") { setTailWidth(times: 1 / 1.25) }
                Text("\(Int((look.tailWidth * 100).rounded()))%")
                    .font(Chrome.valueFont)
                    .foregroundColor(Chrome.text)
                    .frame(minWidth: 46)
                ChromeButton(systemImage: "plus", size: 30, help: "A wider tail") { setTailWidth(times: 1.25) }
                Spacer(minLength: 4)
                if let balloon = viewModel.selectedBalloon, balloon.tail != nil {
                    let pinned = balloon.tailPinned
                    Button {
                        viewModel.pinSelectedTail(!pinned, renderer: actions.renderer())
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: pinned ? "pin.fill" : "pin")
                            Text("tip")
                        }
                        .font(Chrome.labelFont)
                        .foregroundColor(pinned ? Chrome.text : Chrome.secondaryText)
                        .frame(width: 64, height: 30)
                        .overlay(alignment: .bottom) {
                            Rectangle().fill(pinned ? Chrome.accent : Color.clear).frame(height: 2)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help(pinned ? "Let the tail's tip move with the balloon"
                                 : "Pin the tail's tip where it is, so it stays on the speaker as the balloon moves")
                }
            }
        }
    }

    /// The tail's width `times` what it is, in twentieths, within the narrowest and widest.
    private func setTailWidth(times factor: CGFloat) {
        let range = BalloonLook.tailWidths
        editLook("Tail Width") { look in
            look.tailWidth = min(range.upperBound, max(range.lowerBound, (look.tailWidth * factor * 20).rounded() / 20))
        }
    }

    private func lookRow<Content: View>(_ label: String, @ViewBuilder content: () -> Content) -> some View {
        HStack(spacing: 3) {
            Text(label)
                .font(Chrome.labelFont)
                .foregroundColor(Chrome.secondaryText)
                .frame(width: 34, alignment: .leading)
            content()
        }
    }

    /// The pictures' tiles: four to a row for shapes and tails, seven for lines.
    private static let wideTile = CGSize(width: 50, height: 28)
    private static let narrowTile = CGSize(width: 29, height: 28)

    /// A picture of a balloon of `style` in `look`, drawn by the engine on a tile of paper,
    /// so its black line shows on a dark panel as it would on a page.
    private func preview(_ style: BalloonStyle, _ look: BalloonLook, tail: Bool, size: CGSize) -> some View {
        let inner = CGSize(width: size.width - 4, height: size.height - 4)
        return Group {
            if let image = BalloonPreviews.image(style, look: look, tail: tail, size: inner, scale: displayScale) {
                Image(decorative: image, scale: displayScale)
            } else {
                Color.clear
            }
        }
        .frame(width: inner.width, height: inner.height)
        .frame(width: size.width, height: size.height)
        .background(RoundedRectangle(cornerRadius: 4).fill(Color(white: 0.93)))
    }

    private static func help(for line: BalloonLine) -> String {
        switch line {
        case .solid: return "A solid line"
        case .heavy: return "A heavy line"
        case .dashed: return "A dashed line, for a whisper"
        case .double: return "A double line"
        case .wavy: return "A wavy line, for a weak or trembling voice"
        case .electric: return "A zigzag line, for a voice from a radio, a phone or a machine"
        case .none: return "No line"
        }
    }

    private static func help(for tail: BalloonTail) -> String {
        switch tail {
        case .curved: return "A curved tail"
        case .straight: return "A straight tail"
        case .bubbles: return "A trail of bubbles, as a thought has"
        case .lightning: return "A zigzag tail, for a voice from a speaker"
        }
    }

    /// The picked-up balloon's look changed by `edit`, as a step, and the next one's of its
    /// kind; or with none picked up, only the next one's. Edited as it is when chosen, not as
    /// the panel last drew it, so quick choices in a row each keep the last.
    private func editLook(_ kind: String, addingTail: Bool = false, _ edit: (inout BalloonLook) -> Void) {
        let style = viewModel.selectedBalloon?.style ?? viewModel.balloonStyle
        var look = viewModel.selectedBalloon?.look ?? viewModel.balloonLook(for: style)
        edit(&look)
        viewModel.setBalloonLook(look, as: kind, addingTail: addingTail, renderer: actions.renderer())
    }

    private func change(_ kind: String, _ edit: (inout Balloon) -> Void) {
        guard viewModel.selectedBalloonID != nil, let renderer = actions.renderer() else { return }
        viewModel.changeSelectedBalloon(kind, renderer: renderer, edit)
    }
}

/// A choice in the lettering panel's look rows: a picture, dimmed unless chosen, marked
/// underneath in the accent when it is, as `SquareChoice`'s are.
private struct LookChoice<Label: View>: View {
    let isSelected: Bool
    /// Whether it is dimmed unless chosen; a colour is shown as it is.
    var dims = true
    let help: String
    let action: () -> Void
    let label: Label

    init(isSelected: Bool, dims: Bool = true, help: String, action: @escaping () -> Void, @ViewBuilder label: () -> Label) {
        self.isSelected = isSelected
        self.dims = dims
        self.help = help
        self.action = action
        self.label = label()
    }

    var body: some View {
        Button(action: action) {
            label
                .opacity(isSelected || !dims ? 1 : 0.7)
                .frame(maxWidth: .infinity)
                .frame(height: 30)
                .overlay(alignment: .bottom) {
                    Rectangle()
                        .fill(isSelected ? Chrome.accent : Color.clear)
                        .frame(height: 2)
                }
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
    }
}

/// The panel's pictures of balloons, drawn once each by the engine and kept.
@MainActor
enum BalloonPreviews {
    private struct Key: Hashable {
        let style: BalloonStyle
        let look: BalloonLook
        let tail: Bool
        let width: Int
        let height: Int
    }

    private static var drawn: [Key: CGImage] = [:]

    static func image(_ style: BalloonStyle, look: BalloonLook, tail: Bool, size: CGSize, scale: CGFloat) -> CGImage? {
        let key = Key(style: style, look: look, tail: tail, width: Int(size.width * scale), height: Int(size.height * scale))
        if let image = drawn[key] { return image }
        guard let image = BalloonLayout.preview(style, look: look, tail: tail, width: key.width, height: key.height,
                                                scale: scale) else { return nil }
        drawn[key] = image
        return image
    }
}

private extension BalloonLook {
    /// This look with `edit` made to it.
    func with(_ edit: (inout BalloonLook) -> Void) -> BalloonLook {
        var look = self
        edit(&look)
        return look
    }
}
