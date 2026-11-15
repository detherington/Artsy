import XCTest
import Metal
#if canImport(Artsy)
@testable import Artsy
#endif
@testable import ArtsyEngine

/// Colouring a comic page: fills that read the inks and close their gaps, layers clipped
/// to the layer below, and layers whose alpha is locked.
final class FlatsClippingTests: XCTestCase {
    private let red = StrokeColor(red: 1, green: 0, blue: 0, alpha: 1)
    private let blue = StrokeColor(red: 0, green: 0, blue: 1, alpha: 1)
    private let green = StrokeColor(red: 0, green: 1, blue: 0, alpha: 1)

    /// A 128² canvas over nothing, its drawing layer current.
    private func canvas() throws -> EngineHarness {
        let harness = try EngineHarness(width: 128, height: 128)
        harness.fill(harness.backgroundLayer, red: 0, green: 0, blue: 0, alpha: 0)
        harness.layerStack.activeLayerIndex = 1
        return harness
    }

    private func rectangle(_ rect: CGRect, _ colour: StrokeColor, on layer: Layer, in harness: EngineHarness) {
        harness.renderer.drawShape(path: CGPath(rect: rect, transform: nil), strokeColor: nil, fillColor: colour,
                                   strokeWidth: 0, layer: layer, context: harness.context)
    }

    /// Inks: a black box, 4 pixels thick, from 28 to 92 each way; inside it, 32 to 88.
    private func inks(on layer: Layer, in harness: EngineHarness) {
        harness.renderer.drawShape(path: CGPath(rect: CGRect(x: 30, y: 30, width: 60, height: 60), transform: nil),
                                   strokeColor: .black, fillColor: nil, strokeWidth: 4, layer: layer, context: harness.context)
    }

    /// A fill with the view model's options at `point`, waited for.
    private func fill(_ harness: EngineHarness, at point: CGPoint, _ colour: StrokeColor,
                      file: StaticString = #filePath, line: UInt = #line) {
        harness.viewModel.currentColor = colour
        let landed = expectation(description: "filled")
        XCTAssertTrue(harness.viewModel.bucketFill(at: point, renderer: harness.renderer) { landed.fulfill() },
                      file: file, line: line)
        wait(for: [landed], timeout: 20)
    }

    private func assertPixel(_ pixel: SIMD4<Float>, _ expected: SIMD4<Float>, _ message: String,
                             accuracy: Float = 0.02, file: StaticString = #filePath, line: UInt = #line) {
        for c in 0..<4 {
            XCTAssertEqual(pixel[c], expected[c], accuracy: accuracy, "\(message): \(pixel) not \(expected)", file: file, line: line)
        }
    }

    // MARK: - The fill's mask

    /// A box of lines 2 pixels thick with a break 3 wide in its top: an open fill inside
    /// leaks out through the break; with gaps of 2 closed it holds, reaches the lines all
    /// round (corners too), and goes no way into the break.
    func testABreakInTheLinesHoldsOnceGapsAreClosed() {
        let w = 40, h = 40
        var open = [UInt8](repeating: 1, count: w * h)
        for y in 10...29 {
            for x in 10...29 where x <= 11 || x >= 28 || y <= 11 || y >= 28 { open[y * w + x] = 0 }
        }
        for y in 10...11 { for x in 18...20 { open[y * w + x] = 1 } }
        let seed = (x: 20, y: 20)

        let leaky = FillMask.region(open: open, width: w, height: h, seed: seed)!
        XCTAssertEqual(leaky[0], 1, "with no gap closed it leaks out to the corner")

        let held = FillMask.region(open: open, width: w, height: h, seed: seed, closingGaps: 2)!
        XCTAssertEqual(held[0], 0, "closed, it stays inside")
        XCTAssertEqual(held.reduce(0) { $0 + Int($1) }, 16 * 16, "every pixel inside, and no more")
        XCTAssertEqual(held[12 * w + 12], 1, "into the corners")
        XCTAssertEqual(held[27 * w + 27], 1)
        XCTAssertEqual(held[11 * w + 19], 0, "not into the break")

        XCTAssertNil(FillMask.region(open: open, width: w, height: h, seed: (10, 10), closingGaps: 2), "a seed on the lines")
        let nearLine = FillMask.region(open: open, width: w, height: h, seed: (12, 20), closingGaps: 2)
        XCTAssertNotNil(nearLine, "a seed too near the lines for the gap still fills, as an open fill")
    }

    /// Spreading grows a mask by a square of the radius.
    func testSpreadGrowsTheMaskEveryWay() {
        var mask = [UInt8](repeating: 0, count: 12 * 12)
        mask[5 * 12 + 5] = 1
        let grown = FillMask.dilate(mask, width: 12, height: 12, radius: 2)
        XCTAssertEqual(grown.reduce(0) { $0 + Int($1) }, 25)
        XCTAssertEqual(grown[3 * 12 + 3], 1)
        XCTAssertEqual(grown[7 * 12 + 7], 1)
        XCTAssertEqual(grown[5 * 12 + 8], 0)
        XCTAssertEqual(FillMask.dilate(mask, width: 12, height: 12, radius: 0), mask)
    }

    // MARK: - Filling the flats

    /// On a flats layer, with the inks marked as the reference, a fill stays inside the
    /// inks' lines and leaves the inks alone; a second fill in another colour replaces the
    /// first, as the reference, not the colour already down, bounds it. Reading its own
    /// layer, the fill is bounded by what is on the flats.
    func testAFillOnTheFlatsReadsTheInks() throws {
        let harness = try canvas()
        let inksLayer = harness.drawingLayer
        inks(on: inksLayer, in: harness)
        let flats = try harness.addLayer()
        harness.layerStack.activeLayerIndex = 2
        inksLayer.isReference = true
        harness.viewModel.fillSource = .reference

        fill(harness, at: CGPoint(x: 60, y: 60), red)
        var pixels = harness.pixels(of: flats.texture)
        assertPixel(pixels.at(x: 60, y: 60), [1, 0, 0, 1], "inside the box")
        assertPixel(pixels.at(x: 34, y: 86), [1, 0, 0, 1], "into its corner")
        XCTAssertEqual(pixels.at(x: 10, y: 10).w, 0, "not outside it")
        XCTAssertEqual(pixels.at(x: 30, y: 60).w, 0, "nor under the line")
        XCTAssertEqual(harness.pixels(of: inksLayer.texture).at(x: 60, y: 60).w, 0, "the inks untouched")

        fill(harness, at: CGPoint(x: 40, y: 70), blue)
        pixels = harness.pixels(of: flats.texture)
        assertPixel(pixels.at(x: 60, y: 60), [0, 0, 1, 1], "the red replaced")
        XCTAssertEqual(pixels.at(x: 10, y: 10).w, 0)

        // Its own layer: the empty flats outside the blue, under the lines too
        harness.viewModel.fillSource = .layer
        fill(harness, at: CGPoint(x: 10, y: 10), green)
        pixels = harness.pixels(of: flats.texture)
        assertPixel(pixels.at(x: 10, y: 10), [0, 1, 0, 1], "outside")
        assertPixel(pixels.at(x: 30, y: 60), [0, 1, 0, 1], "under the line")
        assertPixel(pixels.at(x: 60, y: 60), [0, 0, 1, 1], "the blue stays")
    }

    /// With no layer marked, a fill that reads the reference reads its own layer.
    func testWithNoReferenceTheFillReadsItsOwnLayer() throws {
        let harness = try canvas()
        inks(on: harness.drawingLayer, in: harness)
        let flats = try harness.addLayer()
        harness.layerStack.activeLayerIndex = 2
        harness.viewModel.fillSource = .reference
        fill(harness, at: CGPoint(x: 60, y: 60), red)
        assertPixel(harness.pixels(of: flats.texture).at(x: 10, y: 10), [1, 0, 0, 1], "the whole empty layer")
    }

    /// Reading all layers, the fill finds its region in the picture as it looks (here
    /// white paper and the inks), and fills on its own layer.
    func testAFillCanReadThePictureAsItLooks() throws {
        let harness = try canvas()
        harness.fill(harness.backgroundLayer, red: 1, green: 1, blue: 1)
        inks(on: harness.drawingLayer, in: harness)
        let flats = try harness.addLayer()
        harness.layerStack.activeLayerIndex = 2
        harness.viewModel.fillSource = .all
        harness.renderFrame()
        fill(harness, at: CGPoint(x: 60, y: 60), red)
        let pixels = harness.pixels(of: flats.texture)
        assertPixel(pixels.at(x: 60, y: 60), [1, 0, 0, 1], "inside")
        XCTAssertEqual(pixels.at(x: 10, y: 10).w, 0, "not the paper outside")
        XCTAssertEqual(harness.pixels(of: harness.backgroundLayer.texture).at(x: 60, y: 60).y, 1, "the paper untouched")
    }

    /// Spread takes the fill under the lines by that many pixels, no further; a gap in the
    /// inks is closed when asked.
    func testSpreadAndGapsOnTheFlats() throws {
        let harness = try canvas()
        let inksLayer = harness.drawingLayer
        inks(on: inksLayer, in: harness)
        // A break 4 high in the box's left side
        clearRect(x: 28...31, y: 58...61, of: inksLayer, in: harness)
        let flats = try harness.addLayer()
        harness.layerStack.activeLayerIndex = 2
        inksLayer.isReference = true
        harness.viewModel.fillSource = .reference

        fill(harness, at: CGPoint(x: 60, y: 60), red)
        XCTAssertEqual(harness.pixels(of: flats.texture).at(x: 10, y: 10).w, 1, accuracy: 0.01, "the open fill leaks out")
        harness.viewModel.performUndo(renderer: harness.renderer)

        harness.viewModel.fillCloseGaps = 3
        harness.viewModel.fillSpread = 3
        fill(harness, at: CGPoint(x: 60, y: 60), blue)
        let pixels = harness.pixels(of: flats.texture)
        XCTAssertEqual(pixels.at(x: 10, y: 10).w, 0, "closed, it holds")
        assertPixel(pixels.at(x: 29, y: 40), [0, 0, 1, 1], "spread under the line")
        XCTAssertEqual(pixels.at(x: 26, y: 40).w, 0, "but no further")
    }

    /// Clears a block of a layer's pixels, canvas coordinates.
    private func clearRect(x: ClosedRange<Int>, y: ClosedRange<Int>, of layer: Layer, in harness: EngineHarness) {
        let texture = layer.texture
        let width = x.count, height = y.count
        let staging = try! harness.renderer.textureManager.makeSharedTexture(width: width, height: height, label: "Clear")
        let zeros = [UInt16](repeating: 0, count: width * height * 4)
        zeros.withUnsafeBytes {
            staging.replace(region: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0, withBytes: $0.baseAddress!,
                            bytesPerRow: width * 8)
        }
        let commandBuffer = harness.context.commandQueue.makeCommandBuffer()!
        let blit = commandBuffer.makeBlitCommandEncoder()!
        blit.copy(from: staging, sourceSlice: 0, sourceLevel: 0, sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0),
                  sourceSize: MTLSize(width: width, height: height, depth: 1), to: texture, destinationSlice: 0,
                  destinationLevel: 0, destinationOrigin: MTLOrigin(x: x.lowerBound, y: texture.height - 1 - y.upperBound, z: 0))
        blit.endEncoding()
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()
    }

    // MARK: - Clipping

    /// Each clipped layer clips to the first unclipped layer under it; the bottom layer
    /// clips to nothing.
    func testAClippedLayersBaseIsTheFirstUnclippedLayerBelow() throws {
        let harness = try canvas()
        let stack = harness.layerStack
        for _ in 0..<4 { try harness.addLayer() }
        // 0 background, 1 A, 2 B, 3 C, 4 D, 5 E
        stack.layers[0].isClipped = true
        stack.layers[2].isClipped = true
        stack.layers[3].isClipped = true
        stack.layers[5].isClipped = true
        XCTAssertNil(stack.clippingBase(of: 0), "the bottom layer")
        XCTAssertNil(stack.clippingBase(of: 1), "not clipped")
        XCTAssertTrue(stack.clippingBase(of: 2) === stack.layers[1])
        XCTAssertTrue(stack.clippingBase(of: 3) === stack.layers[1], "a run clips to one base")
        XCTAssertTrue(stack.clippingBase(of: 5) === stack.layers[4])
        stack.layers[1].isClipped = true
        XCTAssertTrue(stack.clippingBase(of: 3) === stack.layers[0], "down to the bottom, which is always a base")
    }

    /// A layer clipped to the one below shows only where that layer has paint, as do the
    /// clipped layers above it; released, it shows everywhere. The base's opacity is its
    /// clipped layers' too, and hiding the base hides them.
    func testAClippedLayerShowsOnlyThroughItsBase() throws {
        let harness = try canvas()
        let base = harness.drawingLayer
        rectangle(CGRect(x: 32, y: 32, width: 64, height: 64), red, on: base, in: harness)
        let shading = try harness.addLayer()
        harness.fill(shading, red: 0, green: 0, blue: 1)
        shading.isClipped = true

        var shown = harness.composite()
        assertPixel(shown.at(x: 64, y: 64), [0, 0, 1, 1], "over the base")
        assertPixel(shown.at(x: 10, y: 10), [0, 0, 0, 0], "nothing where the base has nothing")

        let light = try harness.addLayer()
        harness.fill(light, red: 0, green: 1, blue: 0, alpha: 0.5)
        light.isClipped = true
        shown = harness.composite()
        assertPixel(shown.at(x: 64, y: 64), [0, 0.5, 0.5, 1], "a second clipped layer, over the first")
        assertPixel(shown.at(x: 10, y: 10), [0, 0, 0, 0], "clipped to the same base")

        light.isClipped = false
        assertPixel(harness.composite().at(x: 10, y: 10), [0, 0.5, 0, 0.5], "released, it shows everywhere")
        light.isVisible = false

        base.opacity = 0.5
        assertPixel(harness.composite().at(x: 64, y: 64), [0.25, 0, 0.5, 0.75], "at the base's opacity")
        base.isVisible = false
        assertPixel(harness.composite().at(x: 64, y: 64), [0, 0, 0, 0], "hidden with its base")
    }

    /// A blend mode applies within the base, as the canvas shows it.
    func testAClippedLayerKeepsItsBlendMode() throws {
        let harness = try canvas()
        let base = harness.drawingLayer
        rectangle(CGRect(x: 32, y: 32, width: 64, height: 64), red, on: base, in: harness)
        let shadow = try harness.addLayer(blendMode: .multiply)
        harness.fill(shadow, red: 0.5, green: 0.5, blue: 0.5)
        shadow.isClipped = true
        let shown = harness.composite()
        assertPixel(shown.at(x: 64, y: 64), [0.5, 0, 0, 1], "multiplied over the base")
        assertPixel(shown.at(x: 10, y: 10), [0, 0, 0, 0], "nothing outside it")
    }

    /// Merging a clipped layer into its base keeps only what showed; flattening, and the
    /// document's thumbnail, show it as the canvas does.
    func testMergingAndFlatteningKeepTheClipping() throws {
        let harness = try canvas()
        let base = harness.drawingLayer
        rectangle(CGRect(x: 32, y: 32, width: 64, height: 64), red, on: base, in: harness)
        let shading = try harness.addLayer()
        harness.fill(shading, red: 0, green: 0, blue: 1)
        shading.isClipped = true

        let thumbnail = try harness.renderer.textureManager.makeCanvasTexture(width: 128, height: 128, label: "Flat")
        let commandBuffer = try XCTUnwrap(harness.context.commandQueue.makeCommandBuffer())
        harness.renderer.textureManager.clearTexture(thumbnail, commandBuffer: commandBuffer)
        harness.renderer.flattenLayers(onto: thumbnail, commandBuffer: commandBuffer)
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()
        assertPixel(harness.pixels(of: thumbnail).at(x: 64, y: 64), [0, 0, 1, 1], "flattened: inside")
        assertPixel(harness.pixels(of: thumbnail).at(x: 10, y: 10), [0, 0, 0, 0], "flattened: outside")

        let flattened = try harness.layerStack.flattenAll(renderer: harness.renderer)
        assertPixel(harness.pixels(of: flattened.texture).at(x: 10, y: 10), [1, 1, 1, 1], "the white page, no blue")
        assertPixel(harness.pixels(of: flattened.texture).at(x: 64, y: 64), [0, 0, 1, 1], "the blue on the red")

        let again = try canvas()
        rectangle(CGRect(x: 32, y: 32, width: 64, height: 64), red, on: again.drawingLayer, in: again)
        let clipped = try again.addLayer()
        again.fill(clipped, red: 0, green: 0, blue: 1)
        clipped.isClipped = true
        XCTAssertTrue(again.layerStack.mergeDown(at: 2, renderer: again.renderer))
        let merged = again.pixels(of: again.drawingLayer.texture)
        assertPixel(merged.at(x: 64, y: 64), [0, 0, 1, 1], "merged: inside")
        assertPixel(merged.at(x: 10, y: 10), [0, 0, 0, 0], "merged: nothing outside")
    }

    // MARK: - Alpha lock

    /// A stroke on a layer with its alpha locked changes the colour of what is there and
    /// adds nothing where nothing is, in the preview as in the commit; the eraser takes
    /// nothing away.
    func testPaintOnALayerWithItsAlphaLockedStaysOnItsPaint() throws {
        let harness = try canvas()
        let layer = harness.drawingLayer
        rectangle(CGRect(x: 32, y: 32, width: 64, height: 64), red, on: layer, in: harness)
        layer.isAlphaLocked = true

        let points = StrokeFixtures.line(from: CGPoint(x: 8, y: 64), to: CGPoint(x: 120, y: 64))
        harness.renderer.beginStroke()
        harness.viewModel.beginStroke(point: points[0], input: .pen)
        for point in points.dropFirst() { harness.viewModel.continueStroke(point: point) }
        let preview = harness.composite()
        assertPixel(preview.at(x: 16, y: 64), [0, 0, 0, 0], "the preview adds nothing off the paint")
        assertPixel(preview.at(x: 64, y: 64), [0, 0, 0, 1], "and paints over it")
        harness.renderer.finalizeStroke()
        harness.viewModel.endStroke()

        var pixels = harness.pixels(of: layer.texture)
        assertPixel(pixels.at(x: 16, y: 64), [0, 0, 0, 0], "nothing where nothing was")
        assertPixel(pixels.at(x: 64, y: 64), [0, 0, 0, 1], "black over the red")
        assertPixel(pixels.at(x: 40, y: 40), [1, 0, 0, 1], "the rest red")

        harness.select(.eraser)
        harness.draw(StrokeFixtures.line(from: CGPoint(x: 8, y: 44), to: CGPoint(x: 120, y: 44)))
        pixels = harness.pixels(of: layer.texture)
        assertPixel(pixels.at(x: 64, y: 44), [1, 0, 0, 1], "the eraser takes nothing")
    }

    /// A fill on a layer with its alpha locked takes the layer's alpha: half-clear paint
    /// stays half clear, and a clear region stays clear.
    func testAFillOnALayerWithItsAlphaLockedKeepsItsAlpha() throws {
        let harness = try canvas()
        let layer = harness.drawingLayer
        rectangle(CGRect(x: 32, y: 32, width: 64, height: 64), StrokeColor(red: 1, green: 0, blue: 0, alpha: 0.5), on: layer, in: harness)
        layer.isAlphaLocked = true
        fill(harness, at: CGPoint(x: 64, y: 64), blue)
        fill(harness, at: CGPoint(x: 10, y: 10), green)
        let pixels = harness.pixels(of: layer.texture)
        assertPixel(pixels.at(x: 64, y: 64), [0, 0, 0.5, 0.5], "blue at the paint's alpha")
        assertPixel(pixels.at(x: 10, y: 10), [0, 0, 0, 0], "nothing on the clear")
    }

    // MARK: - Saving and undo

    func testClippingAlphaLockAndTheReferenceAreSavedAndUndone() throws {
        let harness = try canvas()
        let viewModel = harness.viewModel, renderer = harness.renderer
        try harness.addLayer()
        viewModel.saveUndoSnapshot(renderer: renderer, description: "Clip to Below", changing: .nothing)
        harness.layerStack.layers[2].isClipped = true
        viewModel.saveUndoSnapshot(renderer: renderer, description: "Lock Alpha", changing: .nothing)
        harness.layerStack.layers[2].isAlphaLocked = true
        viewModel.saveUndoSnapshot(renderer: renderer, description: "Reference Layer", changing: .nothing)
        harness.layerStack.layers[1].isReference = true

        viewModel.performUndo(renderer: renderer)
        XCTAssertFalse(harness.layerStack.layers[1].isReference)
        XCTAssertTrue(harness.layerStack.layers[2].isAlphaLocked)
        viewModel.performUndo(renderer: renderer)
        XCTAssertFalse(harness.layerStack.layers[2].isAlphaLocked)
        XCTAssertTrue(harness.layerStack.layers[2].isClipped)
        viewModel.performUndo(renderer: renderer)
        XCTAssertFalse(harness.layerStack.layers[2].isClipped)
        for _ in 0..<3 { viewModel.performRedo(renderer: renderer) }
        XCTAssertTrue(harness.layerStack.layers[2].isClipped)
        XCTAssertTrue(harness.layerStack.layers[2].isAlphaLocked)
        XCTAssertTrue(harness.layerStack.layers[1].isReference)

        let url = FileManager.default.temporaryDirectory.appendingPathComponent("ArtsyFlats-\(UUID().uuidString).artsy")
        defer { try? FileManager.default.removeItem(at: url) }
        let saved = expectation(description: "saved")
        CanvasDocument.saveAsync(renderer: renderer, viewModel: viewModel, to: url) { result in
            if case .failure(let error) = result { XCTFail("\(error)") }
            saved.fulfill()
        }
        wait(for: [saved], timeout: 10)
        let layers = try CanvasDocument.load(from: url, metalContext: harness.context).viewModel.layerStack.layers
        XCTAssertEqual(layers.map(\.isClipped), [false, false, true])
        XCTAssertEqual(layers.map(\.isAlphaLocked), [false, false, true])
        XCTAssertEqual(layers.map(\.isReference), [false, true, false])
    }

    #if canImport(Artsy)
    /// The panel's switches: one reference at a time, the bottom layer never clipped, each
    /// a step to undo.
    func testThePanelsSwitches() throws {
        let harness = try canvas()
        let a = harness.drawingLayer, b = try harness.addLayer()
        let actions = LayerActions(viewModel: harness.viewModel, layerStack: harness.layerStack, renderer: harness.renderer)
        actions.toggleReference(of: a)
        actions.toggleReference(of: b)
        XCTAssertEqual(harness.layerStack.layers.map(\.isReference), [false, false, true], "one at a time")
        actions.toggleClipping(of: harness.backgroundLayer)
        XCTAssertFalse(harness.backgroundLayer.isClipped, "the bottom layer has nothing to clip to")
        actions.toggleClipping(of: b)
        actions.toggleAlphaLock(of: a)
        XCTAssertTrue(b.isClipped)
        XCTAssertTrue(a.isAlphaLocked)

        harness.viewModel.performUndo(renderer: harness.renderer)
        harness.viewModel.performUndo(renderer: harness.renderer)
        XCTAssertFalse(harness.layerStack.layers[2].isClipped)
        harness.viewModel.performUndo(renderer: harness.renderer)
        XCTAssertEqual(harness.layerStack.layers.map(\.isReference), [false, true, false], "back to the first")
    }
    #endif
}
