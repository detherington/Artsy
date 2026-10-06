import Metal
import Foundation
import CoreGraphics
import ImageIO

/// Textures that stamp brushes sample: the paper's tooth, non-round tips, and the images
/// in the user's brush library.
///
/// The built-in ones are generated here rather than shipped as image files, from fixed
/// seeds, so every launch (and every test run) gets the same pixels.
final class BrushTextureLibrary {
    /// The largest tip or grain image that is loaded, per side.
    static let maxImageSide = 4096

    private let device: MTLDevice
    private var tips: [StampSettings.Tip: MTLTexture] = [:]
    private var grains: [StampSettings.Grain.Texture: MTLTexture] = [:]

    /// Where `.image` tips and textures are read from (the brush library's textures folder).
    var userTextureDirectory: URL? {
        didSet {
            if userTextureDirectory != oldValue {
                tips = tips.filter { if case .image = $0.key { return false } else { return true } }
                grains = grains.filter { if case .image = $0.key { return false } else { return true } }
            }
        }
    }

    /// Tileable paper grain; red channel is the height of the paper (1 = a peak).
    private(set) lazy var paperGrain: MTLTexture? = makeTexture(size: Self.grainSize, pixels: Self.paperGrainPixels())
    /// Tileable bristle streaks running along x.
    private(set) lazy var bristleGrain: MTLTexture? = makeTexture(size: Self.grainSize, pixels: Self.bristleGrainPixels())

    /// The grain texture; an image that cannot be found falls back to paper.
    func grainTexture(for texture: StampSettings.Grain.Texture) -> MTLTexture? {
        switch texture {
        case .paper: return paperGrain
        case .bristles: return bristleGrain
        case .image(let name):
            if let cached = grains[texture] { return cached }
            guard let loaded = loadImage(named: name, asTip: false) else { return paperGrain }
            grains[texture] = loaded
            return loaded
        }
    }

    /// Forget any image that has changed on disk.
    func forgetImage(named name: String) {
        tips[.image(name)] = nil
        grains[.image(name)] = nil
    }

    static let grainSize = 512
    static let tipSize = 128

    init(device: MTLDevice) {
        self.device = device
    }

    /// Make the procedural grains and tips now, rather than in the first stroke that needs
    /// them: generating the paper grain alone takes the main thread tens of milliseconds,
    /// which showed as a dropped frame at the first chalk or watercolour stroke of a session.
    func warmUp() {
        _ = paperGrain
        _ = bristleGrain
        _ = tipTexture(for: .chalk)
        _ = tipTexture(for: .bristle)
    }

    /// The image for a tip, or nil for tips the shader draws itself.
    func tipTexture(for tip: StampSettings.Tip) -> MTLTexture? {
        switch tip {
        case .round:
            return nil
        case .chalk, .bristle:
            if let cached = tips[tip] { return cached }
            let pixels = tip == .chalk ? Self.chalkTipPixels() : Self.bristleTipPixels()
            let texture = makeTexture(size: Self.tipSize, pixels: pixels)
            tips[tip] = texture
            return texture
        case .image(let name):
            // A missing image means a round tip, so a brush whose image was deleted still works.
            if let cached = tips[tip] { return cached }
            guard let loaded = loadImage(named: name, asTip: true) else { return nil }
            tips[tip] = loaded
            return loaded
        }
    }

    /// Read a PNG from the user's textures folder as a single-channel texture.
    /// - Parameter asTip: a tip's shape is its alpha channel, or its darkness if it has
    ///   none (a scanned brush mark on white); a grain's height is its brightness.
    private func loadImage(named name: String, asTip: Bool) -> MTLTexture? {
        guard let directory = userTextureDirectory,
              let source = CGImageSourceCreateWithURL(directory.appendingPathComponent(name) as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return nil }
        let width = image.width, height = image.height
        guard width > 0, height > 0, width <= Self.maxImageSide, height <= Self.maxImageSide else { return nil }

        var rgba = [UInt8](repeating: 0, count: width * height * 4)
        let drawn = rgba.withUnsafeMutableBytes { raw -> Bool in
            guard let context = CGContext(data: raw.baseAddress, width: width, height: height, bitsPerComponent: 8,
                                          bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard drawn else { return nil }

        let hasAlpha: [CGImageAlphaInfo] = [.first, .last, .premultipliedFirst, .premultipliedLast, .alphaOnly]
        let shapeIsAlpha = hasAlpha.contains(image.alphaInfo)
        var pixels = [UInt8](repeating: 0, count: width * height)
        for i in 0..<(width * height) {
            let r = Int(rgba[i * 4]), g = Int(rgba[i * 4 + 1]), b = Int(rgba[i * 4 + 2]), a = Int(rgba[i * 4 + 3])
            // Premultiplied, so divide the colour back out before taking its brightness
            let luma = a > 0 ? min(255, (r * 299 + g * 587 + b * 114) / 1000 * 255 / a) : 0
            pixels[i] = UInt8(asTip ? (shapeIsAlpha ? a : 255 - luma) : luma)
        }
        return makeTexture(width: width, height: height, pixels: pixels)
    }

    private func makeTexture(size: Int, pixels: [UInt8]) -> MTLTexture? {
        makeTexture(width: size, height: size, pixels: pixels)
    }

    private func makeTexture(width: Int, height: Int, pixels: [UInt8]) -> MTLTexture? {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .r8Unorm, width: width, height: height, mipmapped: true
        )
        descriptor.usage = [.shaderRead]
        guard let texture = device.makeTexture(descriptor: descriptor) else { return nil }
        // Fill every mip level by box-filtering the one above, so small dabs don't shimmer.
        var level = pixels
        var levelW = width, levelH = height
        var mip = 0
        while true {
            level.withUnsafeBytes {
                texture.replace(region: MTLRegionMake2D(0, 0, levelW, levelH), mipmapLevel: mip,
                                withBytes: $0.baseAddress!, bytesPerRow: levelW)
            }
            guard levelW > 1 || levelH > 1 else { break }
            let nextW = max(1, levelW / 2), nextH = max(1, levelH / 2)
            var next = [UInt8](repeating: 0, count: nextW * nextH)
            for y in 0..<nextH {
                for x in 0..<nextW {
                    let x0 = min(2 * x, levelW - 1), x1 = min(2 * x + 1, levelW - 1)
                    let y0 = min(2 * y, levelH - 1), y1 = min(2 * y + 1, levelH - 1)
                    let sum = Int(level[y0 * levelW + x0]) + Int(level[y0 * levelW + x1])
                            + Int(level[y1 * levelW + x0]) + Int(level[y1 * levelW + x1])
                    next[y * nextW + x] = UInt8(sum / 4)
                }
            }
            level = next
            levelW = nextW
            levelH = nextH
            mip += 1
        }
        return texture
    }

    // MARK: - Generators

    /// Gradient (Perlin) noise that wraps every `periodX` by `periodY` cells, so textures
    /// built from it tile. Output is roughly 0...1, centred on 0.5.
    private struct TileableNoise {
        let periodX: Int
        let periodY: Int
        let seed: UInt64

        init(period: Int, seed: UInt64) {
            self.init(periodX: period, periodY: period, seed: seed)
        }

        init(periodX: Int, periodY: Int, seed: UInt64) {
            self.periodX = periodX
            self.periodY = periodY
            self.seed = seed
        }

        /// A unit gradient for a lattice point.
        private func gradient(_ x: Int, _ y: Int) -> (Float, Float) {
            let wx = UInt64(((x % periodX) + periodX) % periodX)
            let wy = UInt64(((y % periodY) + periodY) % periodY)
            var z = seed &+ wx &* 0x9E3779B97F4A7C15 &+ wy &* 0xD1B54A32D192ED03
            z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
            z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
            z ^= z >> 31
            let angle = Float(z >> 40) / Float(1 << 24) * 2 * .pi
            return (cos(angle), sin(angle))
        }

        /// - Parameters x, y: in cells.
        func value(_ x: Float, _ y: Float) -> Float {
            let x0 = Int(x.rounded(.down)), y0 = Int(y.rounded(.down))
            let fx = x - Float(x0), fy = y - Float(y0)
            func corner(_ dx: Int, _ dy: Int) -> Float {
                let g = gradient(x0 + dx, y0 + dy)
                return g.0 * (fx - Float(dx)) + g.1 * (fy - Float(dy))
            }
            // Quintic fade: no creases along the lattice lines
            let sx = fx * fx * fx * (fx * (fx * 6 - 15) + 10)
            let sy = fy * fy * fy * (fy * (fy * 6 - 15) + 10)
            let top = corner(0, 0) + (corner(1, 0) - corner(0, 0)) * sx
            let bottom = corner(0, 1) + (corner(1, 1) - corner(0, 1)) * sx
            return 0.5 + (top + (bottom - top) * sy) * 0.7
        }
    }

    /// Cold-press paper: a few octaves of noise from fine tooth up to broad unevenness.
    ///
    /// Heights are spread evenly over 0...1 (each value is the pixel's rank), so when a
    /// brush fills the paper up to some height, the share of paper covered is that height:
    /// coverage then grows steadily with pen pressure instead of jumping from none to all.
    static func paperGrainPixels() -> [UInt8] {
        let size = grainSize
        let octaves: [(cells: Int, weight: Float)] = [(171, 0.42), (85, 0.3), (37, 0.18), (11, 0.1)]
        let noises = octaves.enumerated().map { TileableNoise(period: $1.cells, seed: 0xA7C5 &+ UInt64($0) &* 7919) }

        var heights = [Float](repeating: 0, count: size * size)
        for y in 0..<size {
            for x in 0..<size {
                var h: Float = 0
                for (noise, octave) in zip(noises, octaves) {
                    let scale = Float(octave.cells) / Float(size)
                    h += noise.value(Float(x) * scale, Float(y) * scale) * octave.weight
                }
                heights[y * size + x] = h
            }
        }
        let order = heights.indices.sorted { heights[$0] < heights[$1] }
        var pixels = [UInt8](repeating: 0, count: heights.count)
        for (rank, index) in order.enumerated() {
            pixels[index] = UInt8((Float(rank) / Float(heights.count - 1) * 255).rounded())
        }
        return pixels
    }

    /// Streaks along x: fine across the stroke, slowly varying along it, the way a loaded
    /// brush's bristles leave their marks. Heights are spread evenly over 0...1.
    static func bristleGrainPixels() -> [UInt8] {
        let size = grainSize
        // The lattice is 7 cells along x by 112 across y, so the noise is stretched into stripes.
        let streaks = TileableNoise(periodX: 7, periodY: 112, seed: 0xB215)
        let breaks = TileableNoise(period: 28, seed: 0xB216)
        var heights = [Float](repeating: 0, count: size * size)
        for y in 0..<size {
            for x in 0..<size {
                let u = Float(x) / Float(size), v = Float(y) / Float(size)
                let stripe = streaks.value(u * 7, v * 112)
                let gap = breaks.value(u * 28, v * 28)
                heights[y * size + x] = stripe * 0.8 + gap * 0.2
            }
        }
        let order = heights.indices.sorted { heights[$0] < heights[$1] }
        var pixels = [UInt8](repeating: 0, count: heights.count)
        for (rank, index) in order.enumerated() {
            pixels[index] = UInt8((Float(rank) / Float(heights.count - 1) * 255).rounded())
        }
        return pixels
    }

    /// The footprint of a loaded bristle brush: a disc whose edge is ragged where single
    /// bristles stick out, solid inside.
    static func bristleTipPixels() -> [UInt8] {
        let size = tipSize
        let ragged = TileableNoise(period: 16, seed: 0xB217)
        var pixels = [UInt8](repeating: 0, count: size * size)
        for y in 0..<size {
            for x in 0..<size {
                let u = (Float(x) + 0.5) / Float(size), v = (Float(y) + 0.5) / Float(size)
                let dist = hypot(u - 0.5, v - 0.5) * 2
                let angle = atan2(v - 0.5, u - 0.5)
                // Noise around the rim moves the edge in and out
                let rim = ragged.value((angle / (2 * .pi) + 0.5) * 16, dist * 4)
                let edge = 0.72 + (rim - 0.5) * 0.5
                let disc = 1 - min(1, max(0, (dist - (edge - 0.08)) / 0.08))
                pixels[y * size + x] = UInt8((disc * 255).rounded())
            }
        }
        return pixels
    }

    /// The end of a stick of chalk: a disc with a crumbly edge and uneven coverage.
    static func chalkTipPixels() -> [UInt8] {
        let size = tipSize
        let coarse = TileableNoise(period: 7, seed: 0xC4A1)
        let fine = TileableNoise(period: 31, seed: 0xC4A2)
        var pixels = [UInt8](repeating: 0, count: size * size)
        for y in 0..<size {
            for x in 0..<size {
                let u = (Float(x) + 0.5) / Float(size), v = (Float(y) + 0.5) / Float(size)
                let dist = hypot(u - 0.5, v - 0.5) * 2
                let rough = coarse.value(u * 7, v * 7)
                let speckle = fine.value(u * 31, v * 31)
                // The outline wanders in and out with the coarse noise…
                let edge = 0.8 + (rough - 0.5) * 0.5
                let disc = 1 - min(1, max(0, (dist - (edge - 0.1)) / 0.1))
                // …and the face is denser in some places than others.
                let face = 0.6 + 0.5 * (rough - 0.5) + 0.7 * (speckle - 0.5)
                pixels[y * size + x] = UInt8((min(1, max(0, disc * face)) * 255).rounded())
            }
        }
        return pixels
    }
}
