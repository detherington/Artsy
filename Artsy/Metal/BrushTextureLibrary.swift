import Metal
import Foundation

/// Textures that stamp brushes sample: the paper's tooth and non-round tips.
///
/// They are generated here rather than shipped as image files, from fixed seeds, so every
/// launch (and every test run) gets the same pixels.
final class BrushTextureLibrary {
    private let device: MTLDevice
    private var tips: [StampSettings.Tip: MTLTexture] = [:]

    /// Tileable paper grain; red channel is the height of the paper (1 = a peak).
    private(set) lazy var paperGrain: MTLTexture? = makeTexture(size: Self.grainSize, pixels: Self.paperGrainPixels())
    /// Tileable bristle streaks running along x.
    private(set) lazy var bristleGrain: MTLTexture? = makeTexture(size: Self.grainSize, pixels: Self.bristleGrainPixels())

    func grainTexture(for texture: StampSettings.Grain.Texture) -> MTLTexture? {
        switch texture {
        case .paper: return paperGrain
        case .bristles: return bristleGrain
        }
    }

    static let grainSize = 512
    static let tipSize = 128

    init(device: MTLDevice) {
        self.device = device
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
        }
    }

    private func makeTexture(size: Int, pixels: [UInt8]) -> MTLTexture? {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .r8Unorm, width: size, height: size, mipmapped: true
        )
        descriptor.usage = [.shaderRead]
        guard let texture = device.makeTexture(descriptor: descriptor) else { return nil }
        // Fill every mip level by box-filtering the one above, so small dabs don't shimmer.
        var level = pixels
        var levelSize = size
        var mip = 0
        while true {
            level.withUnsafeBytes {
                texture.replace(region: MTLRegionMake2D(0, 0, levelSize, levelSize), mipmapLevel: mip,
                                withBytes: $0.baseAddress!, bytesPerRow: levelSize)
            }
            guard levelSize > 1 else { break }
            let half = levelSize / 2
            var next = [UInt8](repeating: 0, count: half * half)
            for y in 0..<half {
                for x in 0..<half {
                    let sum = Int(level[(2 * y) * levelSize + 2 * x]) + Int(level[(2 * y) * levelSize + 2 * x + 1])
                            + Int(level[(2 * y + 1) * levelSize + 2 * x]) + Int(level[(2 * y + 1) * levelSize + 2 * x + 1])
                    next[y * half + x] = UInt8(sum / 4)
                }
            }
            level = next
            levelSize = half
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
