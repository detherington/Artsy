import Foundation

/// Where a fill reaches, worked on masks of bytes (0 or 1 a pixel, rows top first): the
/// pixels like the seed's, the region of them joined to it, a gap in the lines closed, and
/// the region spread under them. Pure functions, run off the main thread by `BucketFill`,
/// and by the tests directly.
public enum FillMask {
    /// The region of `open` pixels joined to `seed`, side by side (four ways, as a fill
    /// that leaks through a corner would not be wanted). Nil if the seed is not open.
    /// With `closingGaps` above 0, the lines (what is not open) are first thickened by that
    /// much, so a break in them up to twice as wide holds; the region found inside is then
    /// grown back by the same amount, but only over open pixels, so it reaches the lines
    /// and goes at most that far into the gap. A seed too near the lines for that falls back
    /// to the region with no gap closed.
    public static func region(open: [UInt8], width: Int, height: Int, seed: (x: Int, y: Int),
                              closingGaps gap: Int = 0) -> [UInt8]? {
        let seedIndex = seed.y * width + seed.x
        guard open.indices.contains(seedIndex), open[seedIndex] != 0 else { return nil }
        guard gap > 0 else { return flood(open, width: width, height: height, seed: seed) }
        let lines = open.map { $0 == 0 ? UInt8(1) : 0 }
        let thick = dilate(lines, width: width, height: height, radius: gap)
        var narrowed = [UInt8](repeating: 0, count: open.count)
        for i in open.indices where open[i] != 0 && thick[i] == 0 { narrowed[i] = 1 }
        guard narrowed[seedIndex] != 0, var region = flood(narrowed, width: width, height: height, seed: seed) else {
            return flood(open, width: width, height: height, seed: seed)
        }
        grow(&region, within: open, width: width, height: height, steps: gap)
        return region
    }

    /// The pixels joined to `seed` through set pixels of `open`, side by side.
    static func flood(_ open: [UInt8], width: Int, height: Int, seed: (x: Int, y: Int)) -> [UInt8]? {
        guard open[seed.y * width + seed.x] != 0 else { return nil }
        var region = [UInt8](repeating: 0, count: open.count)
        open.withUnsafeBufferPointer { o in
            region.withUnsafeMutableBufferPointer { r in
                @inline(__always) func takes(_ x: Int, _ y: Int) -> Bool {
                    let i = y * width + x
                    return o[i] != 0 && r[i] == 0
                }
                var stack: [Int32] = [Int32(seed.x), Int32(seed.y)]
                stack.reserveCapacity(4096)
                while stack.count >= 2 {
                    let y = Int(stack.removeLast()), x = Int(stack.removeLast())
                    guard takes(x, y) else { continue }
                    var left = x, right = x
                    while left > 0, takes(left - 1, y) { left -= 1 }
                    while right < width - 1, takes(right + 1, y) { right += 1 }
                    for xi in left...right { r[y * width + xi] = 1 }
                    for ny in [y - 1, y + 1] where ny >= 0 && ny < height {
                        var inRun = false
                        for xi in left...right {
                            if takes(xi, ny) {
                                if !inRun { stack.append(Int32(xi)); stack.append(Int32(ny)); inRun = true }
                            } else {
                                inRun = false
                            }
                        }
                    }
                }
            }
        }
        return region
    }

    /// `mask` grown by `radius` pixels every way (a square), in two passes of a sliding
    /// count, so the cost does not depend on the radius.
    public static func dilate(_ mask: [UInt8], width: Int, height: Int, radius: Int) -> [UInt8] {
        guard radius > 0 else { return mask }
        var across = [UInt8](repeating: 0, count: mask.count)
        mask.withUnsafeBufferPointer { m in
            across.withUnsafeMutableBufferPointer { a in
                for y in 0..<height {
                    let row = y * width
                    var count = 0
                    // The window [x - radius, x + radius], primed with its right half
                    for x in 0..<min(radius, width) where m[row + x] != 0 { count += 1 }
                    for x in 0..<width {
                        let enter = x + radius, leave = x - radius - 1
                        if enter < width, m[row + enter] != 0 { count += 1 }
                        if leave >= 0, m[row + leave] != 0 { count -= 1 }
                        a[row + x] = count > 0 ? 1 : 0
                    }
                }
            }
        }
        var result = [UInt8](repeating: 0, count: mask.count)
        across.withUnsafeBufferPointer { a in
            result.withUnsafeMutableBufferPointer { r in
                for x in 0..<width {
                    var count = 0
                    for y in 0..<min(radius, height) where a[y * width + x] != 0 { count += 1 }
                    for y in 0..<height {
                        let enter = y + radius, leave = y - radius - 1
                        if enter < height, a[enter * width + x] != 0 { count += 1 }
                        if leave >= 0, a[leave * width + x] != 0 { count -= 1 }
                        r[y * width + x] = count > 0 ? 1 : 0
                    }
                }
            }
        }
        return result
    }

    /// `region` grown a pixel at a time, `steps` times, onto set pixels of `open` beside it
    /// (eight ways), never onto the lines. Worked outward from the region's edge, so the
    /// cost is one pass over the region and then only the pixels it grows onto.
    static func grow(_ region: inout [UInt8], within open: [UInt8], width: Int, height: Int, steps: Int) {
        guard steps > 0 else { return }
        open.withUnsafeBufferPointer { o in
            region.withUnsafeMutableBufferPointer { r in
                /// Takes the open pixels beside `i` not yet in the region, adding them to `next`.
                @inline(__always) func spread(from i: Int, into next: inout [Int32], taking: Bool) -> Bool {
                    let x = i % width, y = i / width
                    var found = false
                    for dy in -1...1 {
                        let ny = y + dy
                        guard ny >= 0, ny < height else { continue }
                        for dx in -1...1 where dx != 0 || dy != 0 {
                            let nx = x + dx
                            guard nx >= 0, nx < width else { continue }
                            let n = ny * width + nx
                            guard o[n] != 0, r[n] == 0 else { continue }
                            if !taking { return true }
                            r[n] = 1
                            next.append(Int32(n))
                            found = true
                        }
                    }
                    return found
                }
                // The region's edge: its pixels with an open pixel beside them outside it
                var frontier: [Int32] = []
                var unused: [Int32] = []
                for i in 0..<r.count where r[i] != 0 {
                    if spread(from: i, into: &unused, taking: false) { frontier.append(Int32(i)) }
                }
                for _ in 0..<steps where !frontier.isEmpty {
                    var next: [Int32] = []
                    next.reserveCapacity(frontier.count * 2)
                    for i in frontier { _ = spread(from: Int(i), into: &next, taking: true) }
                    frontier = next
                }
            }
        }
    }
}
