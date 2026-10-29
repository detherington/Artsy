import Foundation

/// What is drawing a stroke, as far as its pressure goes.
public enum StrokeInput: String, Codable, Equatable {
    /// A pen with a force sensor: the samples' pressure is its own.
    case pen
    /// A pen with tilt but no force sensor, the USB-C Apple Pencil: its pressure comes from
    /// speed at a pen's pace (`PressureFromSpeed.Pace.pen`), leaning widens its mark without
    /// fading it, and it starts out with the Soft curve unless a curve was chosen for it.
    case penWithoutPressure
    /// A finger, a mouse or a trackpad: its pressure comes from speed at a hand's pace.
    case hand

    /// Whether the samples' pressure is the input's own.
    public var hasPressure: Bool { self == .pen }
}
