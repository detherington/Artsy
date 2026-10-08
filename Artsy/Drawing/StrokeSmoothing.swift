import Foundation

enum SmoothingMode: String, CaseIterable, Identifiable, Codable {
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
    /// The time between the last two samples, taken again for a sample stamped before the
    /// last one.
    private var lastInterval: TimeInterval = 1.0 / 200

    let minCutoff: Double  // Minimum cutoff frequency (lower = more smoothing at low speed)
    let beta: Double       // Speed coefficient (higher = less smoothing at high speed)
    let dCutoff: Double    // Cutoff for derivative filter
    /// Multiplies the measured speed. Positions are in canvas pixels; passing the zoom level
    /// makes the speed screen points per second, so the filter feels the same at any zoom.
    let speedScale: Double

    init(minCutoff: Double = 1.0, beta: Double = 0.007, dCutoff: Double = 1.0, speedScale: Double = 1.0) {
        self.minCutoff = minCutoff
        self.beta = beta
        self.dCutoff = dCutoff
        self.speedScale = speedScale
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
        lastInterval = 1.0 / 200
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

        // A sample stamped before the last one happens: a rest sample is stamped a frame on
        // from the sample before it, and the tablet's next real sample, delivered late, can
        // be stamped earlier than that. It is a sample's time on from the one before it, not
        // a thousandth of a second — which would read as the pen moving a thousand times
        // faster, and the filter letting go of it.
        let elapsed = timestamp - lastTime
        let dt = elapsed >= 0.0005 ? elapsed : lastInterval
        lastInterval = dt
        lastTimestamp = timestamp
        let rate = 1.0 / dt

        // Estimate speed (derivative)
        let dx = (point.x - xFilter.lastValue) * rate
        let dy = (point.y - yFilter.lastValue) * rate

        let edx = dxFilter.filter(value: dx, alpha: Self.alpha(cutoff: dCutoff, rate: rate))
        let edy = dyFilter.filter(value: dy, alpha: Self.alpha(cutoff: dCutoff, rate: rate))

        // Adaptive cutoff based on speed
        let speed = sqrt(edx * edx + edy * edy) * speedScale
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
    /// Screen points per canvas pixel (the zoom level), for the speed-adaptive filter.
    var zoom: CGFloat = 1

    private var oneEuro: OneEuroFilter?
    private var lazyBrush: LazyBrushFilter?
    private var movingAvg: MovingAverageFilter?

    private var lastInput: StrokePoint?
    private var lastOutput: StrokePoint?
    private var smoothedPressure: Float = 0

    func begin() {
        lastInput = nil
        lastOutput = nil
        switch mode {
        case .none:
            break
        case .oneEuro:
            // Slow, deliberate movement is steadied (low cutoff); fast movement passes almost
            // untouched so the stroke doesn't trail the pen. At half strength the cutoff is
            // about 7 Hz at rest and 20 Hz at 500 pt/s, which is 4 pt of lag.
            let s = Double(strength)
            oneEuro = OneEuroFilter(
                minCutoff: 12.0 - s * 10.5,   // 12 Hz (barely any) to 1.5 Hz (heavy)
                beta: 0.05 - s * 0.046,
                speedScale: Double(zoom)
            )
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

        // Pressure is steadied along with position. If only position were smoothed, the
        // stroke would lag the pen while its width did not, and width jitter would stay.
        if let previous = lastInput {
            let dt = Float(max(point.timestamp - previous.timestamp, 0.001))
            let timeConstant = 0.005 + 0.035 * strength   // 5 ms to 40 ms
            smoothedPressure += (point.pressure - smoothedPressure) * dt / (dt + timeConstant)
        } else {
            smoothedPressure = point.pressure
        }

        let output = StrokePoint(
            position: smoothedPos,
            pressure: smoothedPressure,
            tiltX: point.tiltX,
            tiltY: point.tiltY,
            rotation: point.rotation,
            timestamp: point.timestamp
        )
        lastInput = point
        lastOutput = output
        return output
    }

    /// When the pen lifts, the smoothed position can still be short of where the pen was.
    /// This is the point that takes the stroke the rest of the way, or nil if it is already
    /// there. The lazy brush never catches up: its stroke ends where the string left it,
    /// which is how you place the end of a line with it.
    func catchUpPoint() -> StrokePoint? {
        guard mode == .oneEuro || mode == .movingAverage,
              let input = lastInput, let output = lastOutput,
              hypot(input.position.x - output.position.x, input.position.y - output.position.y) > 0.5
        else { return nil }
        return StrokePoint(
            position: input.position,
            pressure: output.pressure,
            tiltX: input.tiltX,
            tiltY: input.tiltY,
            rotation: input.rotation,
            timestamp: input.timestamp
        )
    }

    func end() {
        oneEuro = nil
        lazyBrush = nil
        movingAvg = nil
        lastInput = nil
        lastOutput = nil
    }
}
