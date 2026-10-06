import AppKit

final class TabletEventHandler {

    /// Tracks the current pointing device type from proximity events.
    /// This is the reliable way to detect pen vs eraser — proximity events
    /// fire when the stylus enters range or flips between ends.
    static var currentDeviceType: NSEvent.PointingDeviceType = .pen

    /// The pen most recently seen, by the id its maker burned into it, so settings such as
    /// the pressure curve can follow a particular pen. Nil until a pen has been in range.
    static var currentPenID: UInt64?

    /// The key a pen's own settings are stored under; "default" covers no pen at all.
    static var currentPenKey: String {
        currentPenID.map { String($0, radix: 16) } ?? "default"
    }

    /// Call this from tabletProximity(with:) to update the tracked device type.
    static func handleProximity(event: NSEvent) {
        currentDeviceType = event.pointingDeviceType
        if event.isEnteringProximity, event.uniqueID != 0 {
            currentPenID = event.uniqueID
        }
        fputs("Artsy: proximity — deviceType=\(event.pointingDeviceType.rawValue) entering=\(event.isEnteringProximity) pen=\(currentPenKey) (0=generic,1=pen,2=cursor,3=eraser)\n", stderr)
    }

    /// Whether the eraser end is currently active (based on last proximity event).
    static var isEraserActive: Bool {
        currentDeviceType == .eraser
    }

    /// Extract a StrokePoint from an NSEvent, handling both tablet and mouse input.
    static func strokePoint(from event: NSEvent, in view: NSView) -> StrokePoint {
        let locationInView = view.convert(event.locationInWindow, from: nil)

        let pressure: Float
        let tiltX: Float
        let tiltY: Float
        let rotation: Float

        if isTabletEvent(event) {
            pressure = event.pressure
            tiltX = Float(event.tilt.x)
            tiltY = Float(event.tilt.y)
            rotation = event.rotation
        } else {
            pressure = 0.7
            tiltX = 0
            tiltY = 0
            rotation = 0
        }

        return StrokePoint(
            position: locationInView,
            pressure: pressure,
            tiltX: tiltX,
            tiltY: tiltY,
            rotation: rotation,
            timestamp: event.timestamp
        )
    }

    /// Detect whether a tablet is providing the event. Pen data arrives on native tablet
    /// events and on mouse events tagged as tablet points; `subtype` is only valid on the latter.
    static func isTabletEvent(_ event: NSEvent) -> Bool {
        event.type == .tabletPoint || event.subtype == .tabletPoint
    }
}
