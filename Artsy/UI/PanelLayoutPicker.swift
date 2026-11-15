import SwiftUI
import ArtsyEngine

/// Panel layouts for a comic page, in the Add panel: a layout, how far apart its panels
/// sit and how heavy their borders are, each drawn small at the canvas's shape; added as a
/// layer of borders inside the page's safe area (or the canvas's margin).
struct PanelLayoutPicker: View {
    @ObservedObject var viewModel: CanvasViewModel
    let actions: ChromeActions
    let dismiss: () -> Void
    @State private var layout = PanelLayout.all[4]
    @State private var gutter = PanelGutter.medium
    @State private var border = PanelBorder.medium
    @State private var failure: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 10), count: 3), spacing: 12) {
                ForEach(PanelLayout.all) { item in
                    Button { layout = item } label: {
                        VStack(spacing: 5) {
                            PanelLayoutThumbnail(layout: item, canvasSize: viewModel.canvasSize, page: viewModel.guides.page,
                                                 gutter: gutter, border: border, isSelected: item == layout)
                                .frame(height: 78)
                            Text(item.name.lowercased())
                                .font(Chrome.labelFont)
                                .foregroundColor(item == layout ? Chrome.text : Chrome.secondaryText)
                                .lineLimit(1)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help(item.name)
                }
            }

            choices("gutter") {
                ForEach(PanelGutter.allCases) { choice in
                    SquareChoice(text: choice.rawValue, isSelected: gutter == choice, height: 30, font: Chrome.labelFont,
                                 help: "Panels \(choice.rawValue)ly apart") { gutter = choice }
                }
            }
            choices("border") {
                ForEach(PanelBorder.allCases) { choice in
                    SquareChoice(text: choice.rawValue, isSelected: border == choice, height: 30, font: Chrome.labelFont,
                                 help: "\(choice.rawValue.capitalized) borders") { border = choice }
                }
            }

            Text(viewModel.guides.page == nil
                 ? "On a layer of their own, inside a margin around the canvas."
                 : "On a layer of their own, inside the page's safe area.")
                .font(Chrome.labelFont)
                .foregroundColor(Chrome.secondaryText)
                .fixedSize(horizontal: false, vertical: true)

            Button(action: add) {
                Text("add panels")
                    .font(Chrome.futura(14, bold: true))
                    .foregroundColor(.white)
                    .frame(maxWidth: .infinity, minHeight: 40)
                    .background(Rectangle().fill(Chrome.accent))
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Add the \(layout.name.lowercased()) layout as a layer")

            if let failure {
                Text(failure)
                    .font(Chrome.labelFont)
                    .foregroundColor(Chrome.accent)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 4)
    }

    private func choices<Content: View>(_ label: String, @ViewBuilder _ content: () -> Content) -> some View {
        HStack(spacing: 6) {
            Text(label)
                .font(Chrome.labelFont)
                .foregroundColor(Chrome.secondaryText)
                .frame(width: 52, alignment: .leading)
            content()
        }
    }

    private func add() {
        guard let renderer = actions.renderer() else { return }
        ChromeActions.commitPendingEdits()
        do {
            try layout.addLayer(to: viewModel, renderer: renderer, gutter: gutter, border: border)
            failure = nil
            dismiss()
        } catch {
            failure = error.localizedDescription
        }
    }
}

/// A layout drawn small at the canvas's shape: the canvas, and the panels where they would
/// go, with the gutter and border chosen.
struct PanelLayoutThumbnail: View {
    let layout: PanelLayout
    let canvasSize: CGSize
    let page: PageFrame?
    let gutter: PanelGutter
    let border: PanelBorder
    let isSelected: Bool

    var body: some View {
        Canvas { context, size in
            guard canvasSize.width > 0, canvasSize.height > 0 else { return }
            // Room on every side for the selected one's outline
            let room = CGRect(origin: .zero, size: size).insetBy(dx: 3, dy: 3)
            let scale = min(room.width / canvasSize.width, room.height / canvasSize.height)
            let sheet = CGRect(x: room.midX - canvasSize.width * scale / 2, y: room.midY - canvasSize.height * scale / 2,
                               width: canvasSize.width * scale, height: canvasSize.height * scale)
            context.fill(Path(sheet), with: .color(Chrome.control))
            let area = PanelLayout.area(canvasSize: canvasSize, page: page)
            let ink = isSelected ? Chrome.accent : Chrome.text.opacity(0.75)
            let line = max(1, border.width(across: area.width) * scale)
            for panel in layout.panels(in: area, gutter: gutter.width(across: area.width)) {
                let rect = CGRect(x: sheet.minX + panel.minX * scale, y: sheet.minY + panel.minY * scale,
                                  width: panel.width * scale, height: panel.height * scale)
                context.stroke(Path(rect.insetBy(dx: line / 2, dy: line / 2)), with: .color(ink), lineWidth: line)
            }
            if isSelected {
                context.stroke(Path(sheet.insetBy(dx: -2, dy: -2)), with: .color(Chrome.accent), lineWidth: 1)
            }
        }
    }
}
