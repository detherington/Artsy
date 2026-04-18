import Foundation

enum SmoothingMode: String, CaseIterable, Identifiable {
    case none = "None"
    case oneEuro = "Adaptive"
    case lazyBrush = "Lazy Brush"
    case movingAverage = "Moving Avg"

    var id: String { rawValue }
}

// MARK: - One Euro Filter
// Adaptive smoothing: strong at slow speeds, weak at fast speeds.
// Feels natural — deliberate slow movements get stabilized, fast confident strokes stay sharp.

final class OneEuroFilter {
    private var xFilter: LowPassFilter
    private var yFilter: LowPassFilter
    private var dxFilter: LowPassFilter
    private var dyFilter: LowPassFilter
    private var lastTimestamp: TimeInterval?

    let minCutoff: Double  // Minimum cutoff frequency (lower = more smoothing at low speed)
    let beta: Double       // Speed coefficient (higher = less smoothing at high speed)
    let dCutoff: Double    // Cutoff for derivative filter

    init(minCutoff: Double = 1.0, beta: Double = 0.007, dCutoff: Double = 1.0) {
        self.minCutoff = minCutoff
        self.beta = beta
        self.dCutoff = dCutoff
        self.xFilter = LowPassFilter()
        self.yFilter = LowPassFilter()
        self.dxFilter = LowPassFilter()
        self.dyFilter = LowPassFilter()
    }

    func reset() {
        xFilter = LowPassFilter()
        yFilter = LowPassFilter()
        dxFilter = LowPassFilter()
        dyFilter = LowPassFilter()
        lastTimestamp = nil
    }

    func filter(point: CGPoint, timestamp: TimeInterval) -> CGPoint {
        guard let lastTime = lastTimestamp else {
            lastTimestamp = timestamp
            xFilter.initialize(value: point.x)
            yFilter.initialize(value: point.y)
            dxFilter.initialize(value: 0)
            dyFilter.initialize(value: 0)
            return point
        }

        let dt = max(timestamp - lastTime, 0.001)
        lastTimestamp = timestamp
        let rate = 1.0 / dt

        // Estimate speed (derivative)
        let dx = (point.x - xFilter.lastValue) * rate
        let dy = (point.y - yFilter.lastValue) * rate

        let edx = dxFilter.filter(value: dx, alpha: Self.alpha(cutoff: dCutoff, rate: rate))
        let edy = dyFilter.filter(value: dy, alpha: Self.alpha(cutoff: dCutoff, rate: rate))

        // Adaptive cutoff based on speed
        let speed = sqrt(edx * edx + edy * edy)
        let cutoff = minCutoff + beta * speed

        let a = Self.alpha(cutoff: cutoff, rate: rate)
        let fx = xFilter.filter(value: point.x, alpha: a)
        let fy = yFilter.filter(value: point.y, alpha: a)

        return CGPoint(x: fx, y: fy)
    }

    private static func alpha(cutoff: Double, rate: Double) -> Double {
        let tau = 1.0 / (2.0 * .pi * cutoff)
        let te = 1.0 / rate
        return te / (te + tau)
    }
}

private final class LowPassFilter {
    var lastValue: Double = 0
    private var initialized = false

    func initialize(value: Double) {
        lastValue = value
        initialized = true
    }

    func filter(value: Double, alpha: Double) -> Double {
        if !initialized {
            initialize(value: value)
            return value
        }
        let result = alpha * value + (1.0 - alpha) * lastValue
        lastValue = result
        return result
    }
}

// MARK: - Lazy Brush / String Filter
// Simulates a string tethered between the pen and the drawing point.
// The drawing point only moves when the pen pulls it beyond the string length.
// Great for inking — produces very smooth, deliberate lines.

final class LazyBrushFilter {
    private var anchor: CGPoint?
    let radius: Double  // String length in pixels

    init(radius: Double = 10.0) {
        self.radius = radius
    }

    func reset() {
        anchor = nil
    }

    func filter(point: CGPoint) -> CGPoint {
        guard let anchor = anchor else {
            self.anchor = point
            return point
        }

        let dx = point.x - anchor.x
        let dy = point.y - anchor.y
        let dist = sqrt(dx * dx + dy * dy)

        if dist <= radius {
            return anchor  // Don't move until pen exceeds string length
        }

        // Pull anchor toward pen by excess distance
        let excess = dist - radius
        let nx = dx / dist
        let ny = dy / dist
        let newAnchor = CGPoint(x: anchor.x + nx * excess, y: anchor.y + ny * excess)
        self.anchor = newAnchor
        return newAnchor
    }
}

// MARK: - Moving Average Filter

final class MovingAverageFilter {
    private var buffer: [CGPoint] = []
    let windowSize: Int

    init(windowSize: Int = 5) {
        self.windowSize = max(2, windowSize)
    }

    func reset() {
        buffer.removeAll()
    }

    func filter(point: CGPoint) -> CGPoint {
        buffer.append(point)
        if buffer.count > windowSize {
            buffer.removeFirst()
        }

        let avgX = buffer.reduce(0.0) { $0 + $1.x } / Double(buffer.count)
        let avgY = buffer.reduce(0.0) { $0 + $1.y } / Double(buffer.count)
        return CGPoint(x: avgX, y: avgY)
    }
}

// MARK: - Stroke Smoother (unified interface)

final class StrokeSmoother {
    var mode: SmoothingMode = .none
    var strength: Float = 0.5  // 0.0 to 1.0

    private var oneEuro: OneEuroFilter?
    private var lazyBrush: LazyBrushFilter?
    private var movingAvg: MovingAverageFilter?

    func begin() {
        switch mode {
        case .none:
            break
        case .oneEuro:
            // Map strength: low strength = mild smoothing, high = heavy
            let minCutoff = Double(1.0 + (1.0 - strength) * 4.0)  // 1.0 (strong) to 5.0 (weak)
            let beta = Double(0.001 + strength * 0.01)
            oneEuro = OneEuroFilter(minCutoff: minCutoff, beta: beta)
        case .lazyBrush:
            let radius = Double(2.0 + strength * 28.0)  // 2px to 30px string
            lazyBrush = LazyBrushFilter(radius: radius)
        case .movingAverage:
            let window = Int(2 + strength * 12)  // 2 to 14 point window
            movingAvg = MovingAverageFilter(windowSize: window)
        }
    }

    func filter(_ point: StrokePoint) -> StrokePoint {
        let smoothedPos: CGPoint

        switch mode {
        case .none:
            return point
        case .oneEuro:
            smoothedPos = oneEuro?.filter(point: point.position, timestamp: point.timestamp) ?? point.position
        case .lazyBrush:
            smoothedPos = lazyBrush?.filter(point: point.position) ?? point.position
        case .movingAverage:
            smoothedPos = movingAvg?.filter(point: point.position) ?? point.position
        }

        return StrokePoint(
            position: smoothedPos,
            pressure: point.pressure,
            tiltX: point.tiltX,
            tiltY: point.tiltY,
            rotation: point.rotation,
            timestamp: point.timestamp
        )
    }

    func end() {
        oneEuro = nil
        lazyBrush = nil
        movingAvg = nil
    }
}
