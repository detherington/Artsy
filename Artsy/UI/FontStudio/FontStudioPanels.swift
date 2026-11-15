import SwiftUI
import ArtsyEngine

/// The Font Studio's kerning: the pairs to kern down one side (those kerned, then the usual
/// pairs whose letters are drawn), and the pair in hand set large between two Hs as the
/// kerning moves it, with a suggestion from its outlines, and every usual pair at once.
struct KerningPanel: View {
    @ObservedObject var model: FontStudioModel
    @ObservedObject var library: DrawnFontLibrary
    let font: DrawnFont
    let compact: Bool
    @State private var typed = ""

    static let sample = "AVATAR TAVERN · LATTE · YOU WAY · PAY. T.V."

    var body: some View {
        if compact {
            VStack(alignment: .leading, spacing: 10) {
                pairEditor
                pairList.frame(height: 160)
            }
        } else {
            HStack(alignment: .top, spacing: 16) {
                pairList.frame(width: 170)
                pairEditor
            }
        }
    }

    private var pairList: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                ForEach(model.kerningPairs, id: \.self) { pair in
                    let value = font.kerning[pair] ?? 0
                    Button { model.pair = pair } label: {
                        HStack {
                            Text(pair)
                                .font(.system(size: 17, weight: .medium, design: .monospaced))
                                .foregroundColor(Chrome.text)
                            Spacer()
                            Text(value == 0 ? "–" : "\(value)")
                                .font(Chrome.valueFont)
                                .foregroundColor(value == 0 ? Chrome.secondaryText : Chrome.text)
                        }
                        .padding(.horizontal, 12)
                        .frame(height: 34)
                        .background(pair == model.pair ? Chrome.selected : Color.clear)
                        .overlay(alignment: .leading) { if pair == model.pair { Mark().offset(x: 2) } }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .background(Chrome.panel)
        .overlay(Rectangle().strokeBorder(Chrome.hairline))
    }

    private var pairEditor: some View {
        VStack(alignment: .leading, spacing: 10) {
            KernPreview(font: font, pair: model.pair)
                .frame(maxWidth: .infinity, minHeight: 180, maxHeight: 420)
                .background(Color.white)
                .overlay(Rectangle().strokeBorder(Chrome.hairline))
            PanelSlider("kerning", value: Binding(get: { Float(model.kerning) },
                                                  set: { model.setKerning(Int(($0 / 5).rounded()) * 5) }),
                        range: -300...150) { "\(Int($0.rounded()))" }
                .padding(.horizontal, -16)
            HStack(spacing: 4) {
                ChromeButton(systemImage: "minus", label: "closer", help: "Five units closer") { model.setKerning(model.kerning - 5) }
                ChromeButton(systemImage: "plus", label: "apart", help: "Five units apart") { model.setKerning(model.kerning + 5) }
                ChromeButton(systemImage: "wand.and.stars", label: "suggest", help: "Kern the pair as its outlines suggest") {
                    if let suggested = model.suggestedKerning(for: model.pair) { model.setKerning(suggested) }
                }
                ChromeButton(systemImage: "xmark", label: "none", help: "No kerning for this pair") { model.setKerning(0) }
                Spacer(minLength: 8)
                TextField("pair", text: $typed)
                    .squareField(width: 64)
                    .onSubmit(choose)
                Button("kern", action: choose)
                    .font(Chrome.font)
                    .buttonStyle(.plain)
                    .foregroundColor(Chrome.text)
                    .disabled(typed.count < 2)
            }
            Button(action: model.kernUsualPairs) {
                HStack(spacing: 6) {
                    Image(systemName: "wand.and.stars")
                    Text("kern the usual pairs as suggested")
                }
                .font(Chrome.font)
                .foregroundColor(Chrome.text)
                .padding(.horizontal, 12)
                .frame(height: 34)
                .overlay(Rectangle().strokeBorder(Chrome.hairline))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Suggest kerning for every usual pair (AV, LT, TO…) not kerned yet; one step to undo")
            Text(Self.sample)
                .font(DrawnFonts.font(id: font.id, size: 26, fallback: GlyphSheetDrawing.markFace).map { Font($0) } ?? Chrome.font)
                .foregroundColor(Chrome.text)
                .lineLimit(1)
                .minimumScaleFactor(0.5)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 12)
                .frame(height: 50)
                .background(Chrome.panel)
                .overlay(Rectangle().strokeBorder(Chrome.hairline))
                .id(library.revision)
            Spacer(minLength: 0)
        }
    }

    /// The pair typed, in capitals when only its capitals are drawn.
    private func choose() {
        let letters = Array(typed.trimmingCharacters(in: .whitespaces))
        guard letters.count >= 2 else { return }
        model.pair = String(letters.prefix(2).map { font.setting($0) })
        typed = ""
    }
}

/// A pair of drawn letters set as the font will set them, between two Hs where H is drawn,
/// straight from their strokes, so the kerning shows as it moves.
struct KernPreview: View {
    let font: DrawnFont
    let pair: String

    var body: some View {
        Canvas { context, size in
            let characters = Array(pair)
            guard characters.count == 2 else { return }
            let flank: [Character] = font.glyph(for: "H") != nil ? ["H"] : []
            let sequence = flank + characters + flank
            let spacing = CGFloat(font.spacing)
            var placed: [(path: CGPath, x: CGFloat)] = []
            var x: CGFloat = 0
            for (i, character) in sequence.enumerated() {
                guard let glyph = font.glyph(for: font.setting(character)) else { continue }
                let path = GlyphOutline.path(of: glyph)
                let ink = path.boundingBoxOfPath
                if i > 0, i == flank.count + 1 { x += CGFloat(font.kerning(characters[0], characters[1])) }
                placed.append((path, x + spacing - ink.minX))
                x += ink.width + 2 * spacing
            }
            guard x > 0 else { return }
            // Fit the line and the guides' height, the baseline a third up
            let height = DrawnFont.capHeight - DrawnFont.descender + 160
            let scale = min((size.width - 40) / x, (size.height - 20) / height)
            let left = (size.width - x * scale) / 2
            let baseline = size.height / 2 + (DrawnFont.capHeight / 2) * scale
            var guide = Path()
            guide.move(to: CGPoint(x: 0, y: baseline))
            guide.addLine(to: CGPoint(x: size.width, y: baseline))
            context.stroke(guide, with: .color(Color(red: 0.16, green: 0.22, blue: 0.40).opacity(0.35)), lineWidth: 1)
            for (path, offset) in placed {
                let transform = CGAffineTransform(a: scale, b: 0, c: 0, d: -scale, tx: left + offset * scale, ty: baseline)
                context.fill(Path(path).applying(transform), with: .color(.black), style: FillStyle(eoFill: false))
            }
        }
        .accessibilityLabel("The pair \(pair) set with its kerning")
    }
}

/// The Font Studio's family: how much heavier the bold's pen is and how far the italic
/// leans, the four members set side by side, and how balloons use them.
struct FamilyPanel: View {
    @ObservedObject var model: FontStudioModel
    @ObservedObject var library: DrawnFontLibrary
    let font: DrawnFont

    static let sample = "WHAT DO YOU *MEAN*, NO MORE COFFEE?!"
    /// The plain face that sets characters not drawn yet, in the same style.
    static let plainFace: [DrawnFontStyle: String] = [
        .regular: "AvenirNextCondensed-Medium", .bold: "AvenirNextCondensed-Bold",
        .italic: "AvenirNextCondensed-MediumItalic", .boldItalic: "AvenirNextCondensed-BoldItalic",
    ]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 8) {
                PanelSlider("bold", value: Binding(get: { Float(font.boldness) }, set: { model.setBoldness(CGFloat(($0 * 20).rounded() / 20)) }),
                            range: Float(DrawnFont.boldnessRange.lowerBound)...Float(DrawnFont.boldnessRange.upperBound)) {
                    String(format: "×%.2f", $0)
                }
                .padding(.horizontal, -16)
                PanelSlider("slant", value: Binding(get: { Float(font.slant) }, set: { model.setSlant(CGFloat($0.rounded())) }),
                            range: Float(DrawnFont.slantRange.lowerBound)...Float(DrawnFont.slantRange.upperBound)) {
                    "\(Int($0.rounded()))°"
                }
                .padding(.horizontal, -16)
                ForEach(DrawnFontStyle.allCases) { style in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(style.subfamily.lowercased())
                            .font(Chrome.sectionFont)
                            .tracking(Chrome.sectionTracking)
                            .foregroundColor(Chrome.secondaryText)
                        Text(Self.sample.replacingOccurrences(of: "*", with: ""))
                            .font(DrawnFonts.font(id: font.id, size: 30, style: style, fallback: Self.plainFace[style]).map { Font($0) }
                                  ?? Chrome.font)
                            .foregroundColor(Chrome.text)
                            .lineLimit(1)
                            .minimumScaleFactor(0.4)
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Chrome.panel)
                    .overlay(Rectangle().strokeBorder(Chrome.hairline))
                }
                Text(verbatim: "The bold is your drawing with a heavier pen, the italic your drawing slanted. In the lettering panel a balloon can be set in bold or italic, and a word between asterisks, *like this*, is set in bold italic, as comics stress a word.")
                    .font(Chrome.labelFont)
                    .foregroundColor(Chrome.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 4)
            }
            .id(library.revision)
        }
    }
}
