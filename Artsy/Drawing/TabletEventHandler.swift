import AppKit

final class TabletEventHandler {

    /// Tracks the current pointing device type from proximity events.
    /// This is the reliable way to detect pen vs eraser — proximity events
    /// fire when the stylus enters range or flips between ends.
    static var currentDeviceType: NSEvent.PointingDeviceType = .pen

    /// Call this from tabletProximity(with:) to update the tracked device type.
    static func handleProximity(event: NSEvent) {
        currentDeviceType = event.pointingDeviceType
        fputs("Artsy: proximity — deviceType=\(event.pointingDeviceType.rawValue) entering=\(event.isEnteringProximity) (0=generic,1=pen,2=cursor,3=eraser)\n", stderr)
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

        if event.subtype == .tabletPoint {
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

    /// Detect whether a tablet is providing the event.
    static func isTabletEvent(_ event: NSEvent) -> Bool {
        event.subtype == .tabletPoint
    }
}
