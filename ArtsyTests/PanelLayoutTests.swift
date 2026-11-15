import XCTest
#if canImport(Artsy)
@testable import Artsy
#endif
@testable import ArtsyEngine

/// A comic page's panel layouts: where the panels go, and the layer of borders they make.
final class PanelLayoutTests: XCTestCase {
    private func layout(_ name: String) throws -> PanelLayout {
        try XCTUnwrap(PanelLayout.all.first { $0.name == name })
    }

    // MARK: - Geometry

    /// A six-panel grid fills its area in three rows of two, a gutter apart, top row first.
    func testASixGridFillsItsAreaAGutterApart() throws {
        let area = CGRect(x: 100, y: 50, width: 1000, height: 1540)
        let panels = try layout("Six").panels(in: area, gutter: 20)
        XCTAssertEqual(panels.count, 6)
        XCTAssertEqual(panels[0], CGRect(x: 100, y: 50, width: 490, height: 500))
        XCTAssertEqual(panels[1], CGRect(x: 610, y: 50, width: 490, height: 500), "a gutter to the right of the first")
        XCTAssertEqual(panels[2].minY, 570, "the second row a gutter below the first")
        XCTAssertEqual(panels[5].maxX, area.maxX, accuracy: 0.001, "the last reaches the area's corner")
        XCTAssertEqual(panels[5].maxY, area.maxY, accuracy: 0.001)
    }

    /// Rows and panels take their shares: the stagger's first row is two thirds and a third.
    func testPanelsTakeTheirSharesOfARow() throws {
        let panels = try layout("Stagger").panels(in: CGRect(x: 0, y: 0, width: 920, height: 900), gutter: 20)
        XCTAssertEqual(panels.count, 7, "two, three, two")
        XCTAssertEqual(panels[0].width, 600, accuracy: 0.001, "two shares of the 900 left after the gutter")
        XCTAssertEqual(panels[1].width, 300, accuracy: 0.001)
        let wideTop = try layout("Wide top").panels(in: CGRect(x: 0, y: 0, width: 900, height: 1020), gutter: 20)
        XCTAssertEqual(wideTop[0].height, 600, accuracy: 0.001, "a share and a half of the height")
        XCTAssertEqual(wideTop[1].height, 400, accuracy: 0.001)
        for layout in PanelLayout.all {
            XCTAssertFalse(layout.panels(in: CGRect(x: 0, y: 0, width: 1000, height: 1500), gutter: 30).isEmpty, layout.name)
        }
    }

    /// Panels go inside the page's safe area, turned from the canvas's y-up into the page's
    /// y-down; a canvas with no page keeps a margin of a twentieth of its shorter side.
    func testPanelsGoInsideTheSafeAreaOrAMargin() {
        let size = CGSize(width: 1000, height: 1600)
        var page = PageFrame(canvasSize: size, trimInset: 20, safeInset: 60)
        page.safe = CGRect(x: 60, y: 100, width: 880, height: 1400)  // deeper at the foot, canvas y up
        XCTAssertEqual(PanelLayout.area(canvasSize: size, page: page), CGRect(x: 60, y: 100, width: 880, height: 1400),
                       "100 from the top and 100 from the bottom: the same either way")
        page.safe = CGRect(x: 60, y: 150, width: 880, height: 1400)
        XCTAssertEqual(PanelLayout.area(canvasSize: size, page: page).minY, 50, "150 up from the bottom is 50 down from the top")
        XCTAssertEqual(PanelLayout.area(canvasSize: size, page: nil), CGRect(x: 50, y: 50, width: 900, height: 1500))
    }

    /// Gutters and borders are shares of the width the panels fill, so a page looks the
    /// same at any resolution; a border is never thinner than a pixel.
    func testGuttersAndBordersScaleWithThePage() {
        XCTAssertEqual(PanelGutter.medium.width(across: 2450), 49, "about ⅛ inch on a US page at 400 dpi")
        XCTAssertEqual(PanelGutter.medium.width(across: 3675), 74, "the same at 600 dpi")
        XCTAssertEqual(PanelBorder.medium.width(across: 2450), 10)
        XCTAssertEqual(PanelBorder.thin.width(across: 100), 1)
        XCTAssertLessThan(PanelGutter.narrow.share, PanelGutter.wide.share)
        XCTAssertLessThan(PanelBorder.thin.share, PanelBorder.bold.share)
    }

    // MARK: - The layer

    /// Adding a layout makes a "Panels" layer above the current one: black borders just
    /// inside each panel, nothing in the panels or the gutters; one step undoes it.
    func testAddingALayoutMakesALayerOfBorders() throws {
        let harness = try EngineHarness(width: 400, height: 600)
        let before = harness.layerStack.layers.count
        let layer = try layout("Wide top").addLayer(to: harness.viewModel, renderer: harness.renderer, gutter: .medium, border: .bold)
        XCTAssertEqual(harness.layerStack.layers.count, before + 1)
        XCTAssertEqual(layer.name, "Panels")
        XCTAssertTrue(harness.layerStack.layers[harness.layerStack.activeLayerIndex] === layer, "the new layer is the current one")

        // A margin of 20 (a twentieth of 400); the area 360 × 560; gutter 7, border 3
        let area = PanelLayout.area(canvasSize: CGSize(width: 400, height: 600), page: nil)
        XCTAssertEqual(area, CGRect(x: 20, y: 20, width: 360, height: 560))
        let gutter = PanelGutter.medium.width(across: 360), border = PanelBorder.bold.width(across: 360)
        // The wide panel on top, which a picture upside down would put at the foot
        let panels = try layout("Wide top").panels(in: area, gutter: gutter)
        let pixels = harness.pixels(of: layer.texture)
        // The grid reads canvas y up: a page's y from the top is height - 1 - y
        func at(_ x: CGFloat, _ yDown: CGFloat) -> SIMD4<Float> { pixels.at(x: Int(x), y: 600 - 1 - Int(yDown)) }
        let first = panels[0]
        let onBorder = at(first.midX, first.minY + 1)
        XCTAssertGreaterThan(onBorder.w, 0.9, "the top border of the first panel is drawn")
        XCTAssertLessThan(onBorder.x + onBorder.y + onBorder.z, 0.1, "in black")
        XCTAssertGreaterThan(at(first.minX + 1, first.midY).w, 0.9, "its left border")
        XCTAssertEqual(at(first.midX, first.midY).w, 0, accuracy: 0.01, "nothing inside the panel")
        XCTAssertGreaterThan(at(first.midX, first.maxY - 1).w, 0.9, "its bottom border, past halfway down: the right way up")
        XCTAssertEqual(at(first.midX, first.maxY + gutter / 2).w, 0, accuracy: 0.01, "nothing in the gutter below it")
        XCTAssertEqual(at(10, 10).w, 0, accuracy: 0.01, "nor in the margin")
        XCTAssertEqual(at(first.midX, first.minY + border + 2).w, 0, accuracy: 0.01, "the border is inside the panel, \(border) wide")

        harness.viewModel.performUndo(renderer: harness.renderer)
        XCTAssertEqual(harness.layerStack.layers.count, before, "one step undoes it")
    }
}
