import Foundation

/// What a session learns of the Pencil in hand from the forces its touches report, to tell
/// a Pencil with a force sensor (the first and second generations, the Pro) from one
/// without (the USB-C), which reports a force that never changes rather than none.
///
/// A stroke has pressure of its own once the Pencil's force has been seen to vary, or when
/// its landing sample's force is an estimate an update is expected to. Until then its
/// pressure comes from speed, and a stroke that began so switches to the Pencil's own the
/// moment the force varies (`note` says when): the first stroke of a session with a Pencil
/// that has a sensor, at its first sample or two. A Pencil whose force has read the same
/// through a stroke's worth of samples is taken for one without a sensor from then on,
/// whatever its landing samples claim; one seen to vary is never taken for that.
public struct PencilForce {
    /// Forces this close, as a share of the Pencil's maximum, read as the same.
    public static let sameWithin: Float = 0.002
    /// How many samples of one and the same force, in a row, say there is no sensor.
    public static let steadySamples = 30
    private var first: Float?
    private var sameInARow = 0
    /// Two different forces have been read: a sensor's.
    public private(set) var varies = false
    /// The force has read the same `steadySamples` times in a row and never varied: a
    /// constant's.
    public private(set) var steady = false

    public init() {}

    /// Whether a stroke beginning now has pressure of its own.
    /// - Parameter expectsUpdate: whether the landing sample's force is an estimate an
    ///   update is expected to, which only a sensor's is.
    public func strokeHasPressure(expectsUpdate: Bool) -> Bool {
        guard !steady else { return false }
        return varies || expectsUpdate
    }

    /// A sample's force into the record. Returns whether the force is now known to vary.
    @discardableResult
    public mutating func note(force: Float, maximum: Float) -> Bool {
        guard force > 0, maximum > 0 else { return varies }
        guard let first else {
            self.first = force
            sameInARow = 1
            return varies
        }
        if abs(force - first) > Self.sameWithin * maximum {
            varies = true
            steady = false
        } else if !varies {
            sameInARow += 1
            if sameInARow >= Self.steadySamples { steady = true }
        }
        return varies
    }
}
