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
/// the style, and for the picked-up balloon its words, face, size, capitals and tail.
/// With no balloon picked up, the style, face and capitals are the next one's.
struct LetteringPanel: View {
    @ObservedObject var viewModel: CanvasViewModel
    let actions: ChromeActions
    @ObservedObject private var fonts = DrawnFontLibrary.shared
    @FocusState private var typing: Bool

    static let width: CGFloat = 300

    var body: some View {
        if viewModel.currentTool == .letter, !viewModel.isChromeHidden {
            panel
        }
    }

    private var panel: some View {
        let balloon = viewModel.selectedBalloon
        return VStack(alignment: .leading, spacing: 10) {
            Text("lettering")
                .font(Chrome.futura(15, bold: true))
                .foregroundColor(Chrome.text)
            HStack(spacing: 4) {
                ForEach(BalloonStyle.allCases) { style in
                    SquareChoice(systemImage: style.systemImage, text: style.rawValue,
                                 isSelected: (balloon?.style ?? viewModel.balloonStyle) == style,
                                 height: 46, font: Chrome.labelFont, help: "\(style.rawValue.capitalized) balloon") {
                        setStyle(style)
                    }
                }
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

    /// The style: the picked-up balloon's, and the next one's.
    private func setStyle(_ style: BalloonStyle) {
        viewModel.balloonStyle = style
        change("Balloon Style") { balloon in
            let before = balloon.style
            balloon.style = style
            // A balloon that comes to speak gets a tail; a sound effect's words grow
            if style.hasTail, !before.hasTail, balloon.tail == nil {
                balloon.tail = Balloon.new(style, at: balloon.center, face: balloon.face, fontSize: balloon.fontSize, allCaps: balloon.allCaps).tail
            }
        }
    }

    private func change(_ kind: String, _ edit: (inout Balloon) -> Void) {
        guard viewModel.selectedBalloonID != nil, let renderer = actions.renderer() else { return }
        viewModel.changeSelectedBalloon(kind, renderer: renderer, edit)
    }
}
