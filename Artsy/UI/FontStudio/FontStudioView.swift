import SwiftUI
import UniformTypeIdentifiers
import ArtsyEngine

/// A drawn font's TrueType file, for the exporter: the save panel on the Mac, Save to
/// Files on iPad.
struct FontFile: FileDocument {
    static let type = UTType(filenameExtension: "ttf", conformingTo: .font) ?? .font
    static var readableContentTypes: [UTType] { [type] }

    let data: Data
    let name: String

    init(data: Data, name: String) {
        self.data = data
        self.name = name
    }

    init(configuration: ReadConfiguration) throws {
        data = configuration.file.regularFileContents ?? Data()
        name = configuration.file.filename ?? "Font"
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: data)
    }
}

/// A drawn font's whole family, a folder of its four TrueType files, for the exporter.
struct FontFamilyFolder: FileDocument {
    static var readableContentTypes: [UTType] { [.folder] }

    let files: [(name: String, data: Data)]
    let name: String

    init(files: [(name: String, data: Data)], name: String) {
        self.files = files
        self.name = name
    }

    init(configuration: ReadConfiguration) throws {
        files = (configuration.file.fileWrappers ?? [:]).compactMap { name, wrapper in
            wrapper.regularFileContents.map { (name, $0) }
        }
        name = configuration.file.filename ?? "Family"
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        var wrappers: [String: FileWrapper] = [:]
        for file in files {
            let wrapper = FileWrapper(regularFileWithContents: file.data)
            wrapper.preferredFilename = file.name
            wrappers[file.name] = wrapper
        }
        return FileWrapper(directoryWithFileWrappers: wrappers)
    }
}

/// The Font Studio: the artist's drawn fonts, and the one open drawn a character at a time
/// on its guides. A window of its own on the Mac, as the Brush Studio is; a large sheet on
/// iPad, with Done. Narrow, as on a phone, the list of fonts becomes a menu over the pad.
struct FontStudioView: View {
    @ObservedObject var model: FontStudioModel
    @ObservedObject var library: DrawnFontLibrary
    /// Closes the sheet on iPad; nil on the Mac, where the window closes itself.
    var done: (() -> Void)? = nil

    @State private var exported: FontFile?
    @State private var exporting = false
    @State private var exportedFamily: FontFamilyFolder?
    @State private var exportingFamily = false
    @State private var importing = false
    @State private var importFailure: String?
    @State private var confirmingDelete = false
    @State private var exportFailed = false

    init(model: FontStudioModel, done: (() -> Void)? = nil) {
        self.model = model
        self.library = model.library
        self.done = done
    }

    static let sample = "THE QUICK BROWN FOX JUMPS OVER THE LAZY DOG! 0123456789?"

    var body: some View {
        GeometryReader { geometry in
            let compact = geometry.size.width < 720
            // Taller than wide, as an iPad held upright: the tools go under a larger pad
            let tall = geometry.size.height > geometry.size.width * 1.15
            HStack(spacing: 0) {
                if !compact {
                    fontList
                        .frame(width: 210)
                    Rectangle().fill(Chrome.hairline).frame(width: 1)
                }
                Group {
                    if let font = model.font, font.isDrawn {
                        editor(font, compact: compact, tall: tall)
                    } else if let font = model.font {
                        importedView(font, compact: compact)
                    } else {
                        empty
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .background(Chrome.background)
        // Each file dialog on a view of its own: one view presents only one
        .background {
            ZStack {
                Color.clear.fileExporter(isPresented: $exporting, document: exported, contentType: FontFile.type,
                                         defaultFilename: exported?.name ?? "Lettering") { result in
                    if case .failure(let error) = result { DiagnosticsLog.shared.error(error, doing: "exporting a font") }
                }
                Color.clear.fileExporter(isPresented: $exportingFamily, document: exportedFamily, contentType: .folder,
                                         defaultFilename: exportedFamily?.name ?? "Lettering family") { result in
                    if case .failure(let error) = result { DiagnosticsLog.shared.error(error, doing: "exporting a font family") }
                }
                Color.clear.fileImporter(isPresented: $importing, allowedContentTypes: [.font]) { result in
                    switch result {
                    case .success(let url):
                        do { try model.importFont(from: url) } catch { importFailure = error.localizedDescription }
                    case .failure(let error):
                        importFailure = error.localizedDescription
                    }
                }
            }
        }
        .alert("Couldn't import the font", isPresented: Binding(get: { importFailure != nil }, set: { if !$0 { importFailure = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(importFailure ?? "")
        }
        .alert("Delete \(model.font?.name ?? "this font")?", isPresented: $confirmingDelete) {
            Button("Delete", role: .destructive) { model.deleteFont() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Its letters are gone for good. Balloons set in it go back to their face; documents saved with it keep a copy.")
        }
        .alert("Nothing to export yet", isPresented: $exportFailed) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("Draw a letter or two first: a font file needs at least one.")
        }
    }

    // MARK: - The fonts

    private var fontList: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("fonts")
                .font(Chrome.titleFont)
                .foregroundColor(Chrome.text)
                .padding(16)
            ScrollView {
                VStack(spacing: 0) {
                    ForEach(library.fonts) { font in
                        fontRow(font)
                    }
                }
            }
            Spacer(minLength: 0)
            Rectangle().fill(Chrome.hairline).frame(height: 1)
            fontButtons
                .padding(12)
        }
        .background(Chrome.panel)
    }

    private func fontRow(_ font: DrawnFont) -> some View {
        let selected = font.id == model.fontID
        return Button {
            model.fontID = font.id
        } label: {
            VStack(alignment: .leading, spacing: 2) {
                Text(font.name)
                    .font(Chrome.font)
                    .foregroundColor(Chrome.text)
                    .lineLimit(1)
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(font.isDrawn && font.drawn.isEmpty ? "nothing drawn yet" : "ABC 123")
                        .font(sampleFont(font, size: 20) ?? Chrome.labelFont)
                        .foregroundColor(font.isDrawn && font.drawn.isEmpty ? Chrome.secondaryText : Chrome.text)
                        .lineLimit(1)
                        .id(library.revision)
                    if !font.isDrawn {
                        Text("imported")
                            .font(Chrome.labelFont)
                            .foregroundColor(Chrome.secondaryText)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(selected ? Chrome.selected : Color.clear)
            .overlay(alignment: .leading) {
                if selected { Mark().offset(x: 4) }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var fontButtons: some View {
        HStack(spacing: 4) {
            ChromeButton(systemImage: "plus", label: "new", size: 44, help: "A new font") { model.newFont() }
            ChromeButton(systemImage: "plus.square.on.square", label: "copy", size: 44, help: "A copy of this font") {
                model.duplicate()
            }
            .disabled(model.font?.isDrawn != true)
            ChromeButton(systemImage: "square.and.arrow.down", label: "import", size: 44,
                         help: "Bring in a font file: one exported from Artsy to draw on again, or any .ttf or .otf to letter in") {
                importing = true
            }
            ChromeButton(systemImage: "trash", label: "delete", size: 44, help: "Delete this font") { confirmingDelete = true }
                .disabled(model.font == nil)
        }
    }

    private var empty: some View {
        VStack(spacing: 14) {
            Text("Draw your own lettering")
                .font(Chrome.titleFont)
                .foregroundColor(Chrome.text)
            Text("Draw each letter once on its guides, capitals first. Balloons can then be set in your hand, and the font exported for any other app.")
                .font(Chrome.font)
                .foregroundColor(Chrome.secondaryText)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 380)
            Button { model.newFont() } label: {
                Text("new font")
                    .font(Chrome.font)
                    .foregroundColor(Chrome.text)
                    .frame(width: 160, height: 40)
                    .overlay(Rectangle().strokeBorder(Chrome.hairline))
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if let done {
                Button("Done", action: done)
                    .font(Chrome.font)
                    .buttonStyle(.plain)
                    .foregroundColor(Chrome.accent)
                    .padding(.top, 8)
            }
        }
        .padding(24)
    }

    // MARK: - The font open

    private func editor(_ font: DrawnFont, compact: Bool, tall: Bool) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            header(font, compact: compact)
            if compact { modeChoices }
            switch model.mode {
            case .letters:
                letters(font, compact: compact, tall: tall)
            case .kerning:
                KerningPanel(model: model, library: library, font: font, compact: compact)
            case .family:
                FamilyPanel(model: model, library: library, font: font)
            }
        }
        .padding(16)
    }

    private var modeChoices: some View {
        HStack(spacing: 4) {
            ForEach(FontStudioMode.allCases) { mode in
                SquareChoice(text: mode.rawValue, isSelected: model.mode == mode, height: 34, font: Chrome.font,
                             help: mode.help) {
                    model.mode = mode
                }
                .frame(width: 84)
            }
        }
    }

    @ViewBuilder
    private func letters(_ font: DrawnFont, compact: Bool, tall: Bool) -> some View {
            if compact || tall {
                pad(font)
                    .frame(maxWidth: .infinity)
                    .layoutPriority(1)
                if compact {
                    tools(font)
                } else {
                    HStack(alignment: .top, spacing: 24) {
                        VStack(alignment: .leading, spacing: 8) {
                            characterLabel(font)
                            penChoices
                            versionChoices(font)
                        }
                        .frame(width: 300)
                        VStack(alignment: .leading, spacing: 4) {
                            sliders(font)
                            buttons
                        }
                    }
                }
                characterGrid(font)
                    .frame(minHeight: 96)
            } else {
                HStack(alignment: .top, spacing: 16) {
                    pad(font)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    tools(font)
                        .frame(width: 250)
                }
                characterGrid(font)
                    .frame(height: 150)
            }
            sampleLine(font)
    }

    private func header(_ font: DrawnFont, compact: Bool) -> some View {
        HStack(spacing: 10) {
            if compact {
                SquareMenu(font.name) {
                    ForEach(library.fonts) { other in
                        Button(other.name) { model.fontID = other.id }
                    }
                    Divider()
                    Button("New Font") { model.newFont() }
                    Button("Duplicate") { model.duplicate() }
                    Button("Import Font…") { importing = true }
                    Button("Delete…", role: .destructive) { confirmingDelete = true }
                }
            }
            TextField("name", text: Binding(get: { model.font?.name ?? "" }, set: { model.rename($0) }))
                .textFieldStyle(.plain)
                .font(Chrome.titleFont)
                .foregroundColor(Chrome.text)
                .frame(maxWidth: compact ? .infinity : 260)
                .padding(.horizontal, 8)
                .frame(height: 34)
                .overlay(Rectangle().strokeBorder(Chrome.hairline))
            if !compact {
                Spacer(minLength: 8)
                modeChoices
            }
            Spacer(minLength: 0)
            Menu {
                Button("Regular (.ttf)") {
                    if let file = model.exportedFile() {
                        exported = file
                        exporting = true
                    } else {
                        exportFailed = true
                    }
                }
                Button("Whole Family (four .ttf files)") {
                    if let family = model.exportedFamily() {
                        exportedFamily = family
                        exportingFamily = true
                    } else {
                        exportFailed = true
                    }
                }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "square.and.arrow.up")
                    Text("export")
                }
                .font(Chrome.font)
                .foregroundColor(Chrome.text)
                .padding(.horizontal, 12)
                .frame(height: 34)
                .overlay(Rectangle().strokeBorder(Chrome.hairline))
                .contentShape(Rectangle())
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("Export the font as TrueType, the regular or the whole family, for Font Book and any other app")
            if let done {
                Button("Done", action: done)
                    .font(Chrome.font)
                    .buttonStyle(.plain)
                    .foregroundColor(Chrome.accent)
                    .padding(.leading, 4)
            }
        }
    }

    private func pad(_ font: DrawnFont) -> some View {
        GlyphPad(glyph: font.glyph(for: model.character, version: model.version), guide: model.guide,
                 character: model.character, spacing: font.spacing,
                 pen: model.pen, weight: model.weight, onStroke: { model.add($0) },
                 onCharacter: { model.select($0) }, onStep: { model.step(by: $0) })
    }

    /// The character's versions: its first, and up to two more drawn to vary repeats.
    private func versionChoices(_ font: DrawnFont) -> some View {
        HStack(spacing: 4) {
            Text("version")
                .font(Chrome.sectionFont)
                .tracking(Chrome.sectionTracking)
                .foregroundColor(Chrome.secondaryText)
                .frame(width: 64, alignment: .leading)
            ForEach(0..<DrawnFont.maxVersions, id: \.self) { version in
                let offered = version < model.versionsOffered
                SquareChoice(text: "\(version + 1)", isSelected: model.version == version, height: 30, font: Chrome.valueFont,
                             help: version == 0 ? "The character as drawn first"
                                : "Another version, for when the character repeats: balloons rotate through them") {
                    model.version = version
                }
                .disabled(!offered)
                .opacity(offered ? 1 : 0.3)
            }
        }
    }

    private func tools(_ font: DrawnFont) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            characterLabel(font)
            penChoices
            versionChoices(font)
            sliders(font)
            buttons
            Text(Self.hint)
                .font(Chrome.labelFont)
                .foregroundColor(Chrome.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// The character in hand, what kind it is, and how many are drawn.
    private func characterLabel(_ font: DrawnFont) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(String(model.character))
                .font(.system(size: 40, weight: .regular, design: .serif))
                .foregroundColor(Chrome.text)
                .frame(minWidth: 40)
            VStack(alignment: .leading, spacing: 2) {
                Text(Self.kind(of: model.character))
                    .font(Chrome.font)
                    .foregroundColor(Chrome.text)
                Text("\(font.drawn.count) of \(DrawnFont.characters.count) drawn")
                    .font(Chrome.labelFont)
                    .foregroundColor(Chrome.secondaryText)
            }
        }
    }

    private var penChoices: some View {
        HStack(spacing: 4) {
            ForEach(GlyphPen.allCases) { pen in
                SquareChoice(systemImage: pen.systemImage, text: pen.rawValue, isSelected: model.pen == pen, height: 46,
                             font: Chrome.labelFont, help: pen.help) {
                    model.pen = pen
                }
            }
        }
    }

    private func sliders(_ font: DrawnFont) -> some View {
        VStack(spacing: 0) {
            PanelSlider("weight", value: Binding(get: { Float(model.weight) }, set: { model.weight = CGFloat($0.rounded()) }),
                        range: Float(GlyphPen.weightRange.lowerBound)...Float(GlyphPen.weightRange.upperBound)) {
                "\(Int($0.rounded()))"
            }
            .padding(.horizontal, -16)
            PanelSlider("spacing", value: Binding(get: { Float(font.spacing) }, set: { model.setSpacing(Int($0.rounded())) }),
                        range: Float(DrawnFont.spacingRange.lowerBound)...Float(DrawnFont.spacingRange.upperBound)) {
                "\(Int($0.rounded()))"
            }
            .padding(.horizontal, -16)
        }
    }

    private var buttons: some View {
        HStack(spacing: 4) {
            ChromeButton(systemImage: "arrow.uturn.backward", label: "undo", help: "Undo the last stroke (⌘Z)") { model.undo() }
                .disabled(!model.canUndo)
                .keyboardShortcut("z", modifiers: .command)
            ChromeButton(systemImage: "arrow.uturn.forward", label: "redo", help: "Redo (⇧⌘Z)") { model.redo() }
                .disabled(!model.canRedo)
                .keyboardShortcut("z", modifiers: [.command, .shift])
            ChromeButton(systemImage: "trash", label: "clear", help: "Draw this character again") { model.clear() }
                .disabled(model.glyph == nil)
            Spacer(minLength: 0)
            ChromeButton(systemImage: "chevron.left", label: "back", help: "The character before (←)") { model.step(by: -1) }
            ChromeButton(systemImage: "chevron.right", label: "next", help: "The next character (→)") { model.step(by: 1) }
        }
    }

    #if os(macOS)
    static let hint = "Draw over the letter on its guides. Type a character to turn to it. A second or third version is drawn over the first, and repeats rotate through them."
    #else
    static let hint = "Draw over the letter on its guides. A second or third version is drawn over the first, and repeats rotate through them."
    #endif

    private func characterGrid(_ font: DrawnFont) -> some View {
        let drawn = font.drawn
        let set = sampleFont(font, size: 22)
        return ScrollViewReader { scroller in
            ScrollView {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 40, maximum: 52), spacing: 4)], spacing: 4) {
                    ForEach(DrawnFont.characters, id: \.self) { character in
                        let isDrawn = drawn.contains(character)
                        Button { model.character = character } label: {
                            Text(String(character))
                                .font(isDrawn ? set ?? .system(size: 20) : .system(size: 18, weight: .light))
                                .foregroundColor(isDrawn ? Chrome.text : Chrome.secondaryText.opacity(0.7))
                                .frame(maxWidth: .infinity, minHeight: 40)
                                .overlay(alignment: .topTrailing) {
                                    let versions = font.versions(of: character)
                                    if versions > 1 {
                                        Text("\(versions)")
                                            .font(Chrome.futura(9))
                                            .foregroundColor(Chrome.secondaryText)
                                            .padding(3)
                                    }
                                }
                                .background(Chrome.panel)
                                .overlay(Rectangle().strokeBorder(character == model.character ? Chrome.accent : Chrome.hairline,
                                                                  lineWidth: character == model.character ? 2 : 1))
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .id(character)
                        .accessibilityLabel("\(String(character)), \(isDrawn ? "drawn" : "not drawn yet")")
                    }
                }
                .id(library.revision)
            }
            .onChange(of: model.character) { _, character in
                withAnimation(.easeInOut(duration: 0.2)) { scroller.scrollTo(character, anchor: .center) }
            }
        }
    }

    private func sampleLine(_ font: DrawnFont) -> some View {
        // Repeats in their other versions, as a balloon sets them
        Text(font.drawn.isEmpty ? "Words set in the font will show here." : DrawnFonts.vary(Self.sample, font: font.id))
            .font(font.drawn.isEmpty ? Chrome.font : sampleFont(font, size: 26) ?? Chrome.font)
            .foregroundColor(font.drawn.isEmpty ? Chrome.secondaryText : Chrome.text)
            .lineLimit(2)
            .minimumScaleFactor(0.5)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 12)
            .frame(height: 56)
            .background(Chrome.panel)
            .overlay(Rectangle().strokeBorder(Chrome.hairline))
            .id(library.revision)
    }

    /// The font as compiled so far, characters it lacks in the plain face.
    private func sampleFont(_ font: DrawnFont, size: CGFloat) -> Font? {
        DrawnFonts.font(id: font.id, size: size, fallback: GlyphSheetDrawing.markFace).map { Font($0) }
    }

    // MARK: - An imported font

    /// A font brought in as it is: its name, set in itself, and what it can and cannot do.
    private func importedView(_ font: DrawnFont, compact: Bool) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                TextField("name", text: Binding(get: { model.font?.name ?? "" }, set: { model.rename($0) }))
                    .textFieldStyle(.plain)
                    .font(Chrome.titleFont)
                    .foregroundColor(Chrome.text)
                    .frame(maxWidth: 320)
                    .padding(.horizontal, 8)
                    .frame(height: 34)
                    .overlay(Rectangle().strokeBorder(Chrome.hairline))
                Spacer(minLength: 0)
                if let done {
                    Button("Done", action: done)
                        .font(Chrome.font)
                        .buttonStyle(.plain)
                        .foregroundColor(Chrome.accent)
                }
            }
            Text("Imported. Balloons are set in it as it is; its letters can't be drawn on here. Draw a font of your own to vary and kern its letters.")
                .font(Chrome.font)
                .foregroundColor(Chrome.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
            if font.imported?.embeddable == false {
                Text("Its maker doesn't allow it to travel inside documents, so a page opened where it isn't imported sets its balloons in their face.")
                    .font(Chrome.labelFont)
                    .foregroundColor(Chrome.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
            ForEach(["THE QUICK BROWN FOX JUMPS", "OVER THE LAZY DOG! 0123456789?", "The quick brown fox jumps."], id: \.self) { line in
                Text(line)
                    .font(sampleFont(font, size: compact ? 28 : 40) ?? Chrome.font)
                    .foregroundColor(Chrome.text)
                    .lineLimit(1)
                    .minimumScaleFactor(0.4)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(Chrome.panel)
            .overlay(Rectangle().strokeBorder(Chrome.hairline))
            .id(library.revision)
            Spacer(minLength: 0)
        }
        .padding(16)
    }

    static func kind(of character: Character) -> String {
        if DrawnFont.capitals.contains(character) { return "capital" }
        if DrawnFont.smallLetters.contains(character) { return "small letter" }
        if DrawnFont.figures.contains(character) { return "figure" }
        return "punctuation"
    }
}

extension FontStudioMode {
    var help: String {
        switch self {
        case .letters: return "Draw the letters, and other versions of them"
        case .kerning: return "Set pairs of letters closer or further apart"
        case .family: return "The bold and the italic drawn from your letters"
        }
    }
}

extension GlyphPen {
    var systemImage: String {
        switch self {
        case .marker: return "pencil.tip"
        case .brush: return "paintbrush.pointed"
        case .chisel: return "highlighter"
        }
    }

    var help: String {
        switch self {
        case .marker: return "A round marker, the same width all the way"
        case .brush: return "A round brush, wider the harder the pen presses"
        case .chisel: return "A broad nib held at an angle: thick one way, thin the other"
        }
    }
}
