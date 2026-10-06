import XCTest
import Metal
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
@testable import Artsy

/// Drives the real renderer without a window: replay strokes into it, read pixels back.
///
/// Everything goes through the same `CanvasViewModel` → `CanvasRenderer` path the app uses;
/// the only thing skipped is presenting to a drawable.
final class EngineHarness {
    /// Building the pipelines compiles every shader, so share one context across tests.
    static let sharedContext: MetalContext = {
        do { return try MetalContext() } catch { fatalError("Metal unavailable: \(error)") }
    }()

    let context: MetalContext
    let viewModel: CanvasViewModel
    let renderer: CanvasRenderer
    let width: Int
    let height: Int

    var layerStack: LayerStack { viewModel.layerStack }
    var backgroundLayer: Layer { layerStack.layers[0] }
    var drawingLayer: Layer { layerStack.layers[1] }

    init(width: Int = 512, height: Int = 288) throws {
        self.context = Self.sharedContext
        self.width = width
        self.height = height
        viewModel = CanvasViewModel(canvasSize: CGSize(width: width, height: height))
        viewModel.recorder = nil
        renderer = try CanvasRenderer(context: context, canvasSize: viewModel.canvasSize)
        renderer.viewModel = viewModel
        try renderer.setupLayerStack(for: viewModel)
        // Known settings, whatever the host app's saved preferences say.
        select(.hardRound)
        viewModel.currentColor = .black
        viewModel.brushOpacity = 1
        viewModel.pressureCurve = .linear
        viewModel.smoothingMode = .none
        viewModel.symmetryMode = .off
        viewModel.easesStrokesWithoutPressure = true
    }

    // MARK: - Setup

    /// Pick a brush at its base size.
    func select(_ brush: BrushDescriptor) {
        viewModel.currentBrush = brush
        viewModel.brushSize = brush.baseSize
    }

    /// Replace a layer's contents with one colour (straight RGBA in; stored premultiplied).
    func fill(_ layer: Layer, red: Double, green: Double, blue: Double, alpha: Double = 1) {
        let commandBuffer = context.commandQueue.makeCommandBuffer()!
        renderer.textureManager.clearTexture(
            layer.texture, commandBuffer: commandBuffer,
            color: MTLClearColor(red: red * alpha, green: green * alpha, blue: blue * alpha, alpha: alpha)
        )
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()
    }

    @discardableResult
    func addLayer(blendMode: LayerBlendMode = .normal, opacity: Float = 1) throws -> Layer {
        let index = try layerStack.addLayer(above: layerStack.layers.count - 1)
        let layer = layerStack.layers[index]
        layer.blendMode = blendMode
        layer.opacity = opacity
        fill(layer, red: 0, green: 0, blue: 0, alpha: 0)
        return layer
    }

    // MARK: - Drawing

    /// Render one frame up to the composite texture and wait for the GPU. Tests write
    /// layers directly (fills, tool commits), so the composite is always rebuilt here; a
    /// frame that may skip it is `renderFrameAsTheAppWould()`.
    func renderFrame() {
        renderer.invalidateComposite()
        renderFrameAsTheAppWould()
    }

    /// A frame exactly as the app's display loop runs it, which skips rebuilding the
    /// composite when nothing it knows of has changed.
    func renderFrameAsTheAppWould() {
        let commandBuffer = context.commandQueue.makeCommandBuffer()!
        renderer.encodeFrame(into: commandBuffer)
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()
    }

    /// Replay one stroke the way the app sees it: pen down, samples arriving with frames
    /// rendered in between, pen up.
    /// - Parameter hasPressure: false to draw as a mouse would (the samples' pressure is
    ///   then a constant the engine may ease in and out).
    func draw(_ points: [StrokePoint], pointsPerFrame: Int = 3, hasPressure: Bool = true) {
        guard let first = points.first else { return }
        renderer.beginStroke()
        viewModel.beginStroke(point: first, hasPressure: hasPressure)
        for (index, point) in points.dropFirst().enumerated() {
            viewModel.continueStroke(point: point)
            if (index + 1) % pointsPerFrame == 0 { renderFrame() }
        }
        renderer.finalizeStroke()
        viewModel.endStroke()
    }

    func draw(_ stroke: RecordedStroke, pointsPerFrame: Int = 3, file: StaticString = #filePath, line: UInt = #line) {
        guard stroke.applySettings(to: viewModel) else {
            XCTFail("Unknown brush \"\(stroke.brushName)\" in recorded stroke", file: file, line: line)
            return
        }
        draw(stroke.points.map(\.strokePoint), pointsPerFrame: pointsPerFrame, hasPressure: stroke.hasPressure ?? true)
    }

    // MARK: - Readback

    /// Raw premultiplied contents of a canvas texture.
    func pixels(of texture: MTLTexture) -> PixelGrid {
        let readable = try! renderer.textureManager.makeSharedTexture(
            width: texture.width, height: texture.height, label: "HarnessReadback"
        )
        let commandBuffer = context.commandQueue.makeCommandBuffer()!
        let blit = commandBuffer.makeBlitCommandEncoder()!
        blit.copy(from: texture, to: readable)
        blit.endEncoding()
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()

        var half = [UInt16](repeating: 0, count: texture.width * texture.height * 4)
        half.withUnsafeMutableBytes {
            readable.getBytes($0.baseAddress!, bytesPerRow: texture.width * 8,
                              from: MTLRegionMake2D(0, 0, texture.width, texture.height), mipmapLevel: 0)
        }
        return PixelGrid(width: texture.width, height: texture.height,
                         values: half.map { Float(Float16(bitPattern: $0)) })
    }

    /// Render a frame and return the composite (premultiplied).
    func composite() -> PixelGrid {
        renderFrame()
        return pixels(of: renderer.compositeTexture)
    }

    /// Render a frame and return what the display shader would show: the composite over white.
    func displayed() -> PixelGrid {
        composite().flattenedOverWhite()
    }

    /// Render a frame through the display shader itself, one canvas pixel per output pixel:
    /// the composite over white with thick paint lit. 8-bit, so values are multiples of 1/255.
    func shown(relief: Float = 1) -> PixelGrid {
        Self.shown(by: renderer, relief: relief)
    }

    /// `shown(relief:)` for any renderer — a loaded document's, say.
    static func shown(by renderer: CanvasRenderer, relief: Float = 1) -> PixelGrid {
        let context = renderer.context
        let width = Int(renderer.canvasSize.width), height = Int(renderer.canvasSize.height)
        let desc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm, width: width, height: height, mipmapped: false
        )
        desc.usage = [.renderTarget, .shaderRead]
        desc.storageMode = .shared
        let target = context.device.makeTexture(descriptor: desc)!
        let commandBuffer = context.commandQueue.makeCommandBuffer()!
        renderer.invalidateComposite()
        renderer.encodeFrame(into: commandBuffer)
        var transform = CanvasTransform()
        transform.scale = 1
        transform.offset = CGPoint(x: -Double(width) / 2, y: -Double(height) / 2)
        renderer.compositor.renderToScreen(
            composite: renderer.compositeTexture, height: renderer.compositeHeightTexture, relief: relief,
            drawable: target, transform: transform, viewSize: CGSize(width: width, height: height),
            backgroundColor: (1, 1, 1), commandBuffer: commandBuffer
        )
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()

        var bgra = [UInt8](repeating: 0, count: width * height * 4)
        target.getBytes(&bgra, bytesPerRow: width * 4, from: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0)
        var values = [Float](repeating: 1, count: width * height * 4)
        for i in 0..<(width * height) {
            values[i * 4] = Float(bgra[i * 4 + 2]) / 255
            values[i * 4 + 1] = Float(bgra[i * 4 + 1]) / 255
            values[i * 4 + 2] = Float(bgra[i * 4]) / 255
        }
        return PixelGrid(width: width, height: height, values: values)
    }

    /// A layer's paint thickness, in each pixel's `.x`; zero everywhere for a layer without any.
    func heights(of layer: Layer) -> PixelGrid {
        var values = [Float](repeating: 0, count: width * height * 4)
        if let heightMap = layer.heightTexture {
            let readable = try! renderer.textureManager.makeHeightTexture(
                width: heightMap.width, height: heightMap.height, label: "HarnessHeights", shared: true
            )
            let commandBuffer = context.commandQueue.makeCommandBuffer()!
            let blit = commandBuffer.makeBlitCommandEncoder()!
            blit.copy(from: heightMap, to: readable)
            blit.endEncoding()
            commandBuffer.commit()
            commandBuffer.waitUntilCompleted()
            var half = [UInt16](repeating: 0, count: width * height)
            half.withUnsafeMutableBytes {
                readable.getBytes($0.baseAddress!, bytesPerRow: width * 2,
                                  from: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0)
            }
            for i in 0..<(width * height) { values[i * 4] = Float(Float16(bitPattern: half[i])) }
        }
        return PixelGrid(width: width, height: height, values: values)
    }
}

/// RGBA float pixels read back from a canvas texture. Row 0 is the top of the texture;
/// use `at(x:y:)` to index in canvas coordinates (origin bottom-left, Y up).
struct PixelGrid {
    let width: Int
    let height: Int
    var values: [Float]

    func at(x: Int, y: Int) -> SIMD4<Float> {
        let row = height - 1 - y
        let i = (row * width + x) * 4
        return SIMD4(values[i], values[i + 1], values[i + 2], values[i + 3])
    }

    var maxColourValue: Float {
        var peak: Float = 0
        for i in stride(from: 0, to: values.count, by: 4) {
            peak = max(peak, values[i], values[i + 1], values[i + 2])
        }
        return peak
    }

    func flattenedOverWhite() -> PixelGrid {
        var out = self
        for i in stride(from: 0, to: values.count, by: 4) {
            let through = 1 - values[i + 3]
            out.values[i] = values[i] + through
            out.values[i + 1] = values[i + 1] + through
            out.values[i + 2] = values[i + 2] + through
            out.values[i + 3] = 1
        }
        return out
    }

    /// 8-bit RGBA, clamped the way an 8-bit drawable clamps.
    var bytes: [UInt8] {
        values.map { UInt8((max(0, min(1, $0)) * 255).rounded()) }
    }
}

// MARK: - Golden images

enum Golden {
    /// `ArtsyTests/Golden/`, next to this file in the source tree.
    static let directory = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Golden")
    static let failuresDirectory = directory.appendingPathComponent("failures")

    /// Set `TEST_RUNNER_ARTSY_RECORD_GOLDENS=1` on the xcodebuild command line to overwrite every golden.
    static let isRecording = ProcessInfo.processInfo.environment["ARTSY_RECORD_GOLDENS"] == "1"

    /// A channel may differ by this much (of 255) before a pixel counts as different.
    static let channelTolerance = 3
    /// Fraction of pixels allowed to differ; absorbs edge pixels that round differently.
    static let allowedDifferentFraction = 0.0005

    private static let colorSpace = CGColorSpace(name: CGColorSpace.displayP3)!

    static func write(_ grid: PixelGrid, to url: URL) throws {
        var bytes = grid.bytes
        let image = bytes.withUnsafeMutableBytes { raw -> CGImage? in
            CGContext(data: raw.baseAddress, width: grid.width, height: grid.height,
                      bitsPerComponent: 8, bytesPerRow: grid.width * 4, space: colorSpace,
                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)?.makeImage()
        }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard let image,
              let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)
        else { throw CocoaError(.fileWriteUnknown) }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { throw CocoaError(.fileWriteUnknown) }
    }

    static func read(_ url: URL) -> (width: Int, height: Int, bytes: [UInt8])? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return nil }
        var bytes = [UInt8](repeating: 0, count: image.width * image.height * 4)
        let drawn = bytes.withUnsafeMutableBytes { raw -> Bool in
            guard let context = CGContext(data: raw.baseAddress, width: image.width, height: image.height,
                                          bitsPerComponent: 8, bytesPerRow: image.width * 4, space: colorSpace,
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
            return true
        }
        return drawn ? (image.width, image.height, bytes) : nil
    }

    /// Compare what the display would show against `Golden/<name>.png`.
    ///
    /// A missing golden is recorded and the test fails once so the new image gets looked at.
    /// On a mismatch the rendered image and a difference map land in `Golden/failures/`.
    static func assertMatches(_ grid: PixelGrid, named name: String,
                              file: StaticString = #filePath, line: UInt = #line) {
        let url = directory.appendingPathComponent("\(name).png")
        do {
            if isRecording {
                try write(grid, to: url)
                return
            }
            guard let golden = read(url) else {
                try write(grid, to: url)
                XCTFail("No golden image for \"\(name)\" — recorded \(url.path). Check it, then re-run.",
                        file: file, line: line)
                return
            }
            guard golden.width == grid.width, golden.height == grid.height else {
                XCTFail("\"\(name)\": golden is \(golden.width)×\(golden.height), render is \(grid.width)×\(grid.height)",
                        file: file, line: line)
                return
            }

            let actual = grid.bytes
            var different = 0
            var worst = 0
            var diff = PixelGrid(width: grid.width, height: grid.height,
                                 values: [Float](repeating: 1, count: actual.count))
            for pixel in 0..<(grid.width * grid.height) {
                var delta = 0
                for channel in 0..<3 {
                    delta = max(delta, abs(Int(actual[pixel * 4 + channel]) - Int(golden.bytes[pixel * 4 + channel])))
                }
                worst = max(worst, delta)
                if delta > channelTolerance {
                    different += 1
                    // Red where the images disagree, stronger for bigger differences.
                    let strength = min(1, 0.35 + Float(delta) / 96)
                    diff.values[pixel * 4 + 1] = 1 - strength
                    diff.values[pixel * 4 + 2] = 1 - strength
                }
            }

            let allowed = Int(Double(grid.width * grid.height) * allowedDifferentFraction)
            guard different > allowed else { return }

            let actualURL = failuresDirectory.appendingPathComponent("\(name).actual.png")
            let diffURL = failuresDirectory.appendingPathComponent("\(name).diff.png")
            try write(grid, to: actualURL)
            try write(diff, to: diffURL)
            XCTFail("""
                "\(name)" no longer matches its golden image: \(different) pixels differ (worst channel delta \(worst)/255).
                Rendered: \(actualURL.path)
                Difference: \(diffURL.path)
                If the change is intended, re-record with TEST_RUNNER_ARTSY_RECORD_GOLDENS=1.
                """, file: file, line: line)
        } catch {
            XCTFail("Golden image I/O failed for \"\(name)\": \(error)", file: file, line: line)
        }
    }
}

extension BrushDescriptor {
    /// A soft-edged ribbon brush with a known falloff, for tests that are about compositing
    /// rather than about how any built-in brush looks.
    static let testSoftRibbon = BrushDescriptor(
        id: UUID(uuidString: "00000000-0000-0000-0000-0000000000F1")!,
        name: "Test Soft Ribbon",
        category: .painting,
        hardness: 0.0,
        baseSize: 24,
        pressureDynamics: PressureDynamics(sizeRange: 0.5...1.0, opacityRange: 0.2...1.0),
        opacity: 1.0,
        smoothing: 0,
        fixedNibAngle: nil
    )
}
