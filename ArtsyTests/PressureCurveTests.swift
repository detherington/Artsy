import XCTest
import SwiftUI
import AppKit
@testable import Artsy

final class PressureCurveTests: XCTestCase {

    func testLinearCurveEndpoints() {
        let curve = PressureCurve.linear
        XCTAssertEqual(curve.map(0.0), 0.0, accuracy: 0.01)
        XCTAssertEqual(curve.map(1.0), 1.0, accuracy: 0.01)
    }

    func testLinearCurveMidpoint() {
        let curve = PressureCurve.linear
        XCTAssertEqual(curve.map(0.5), 0.5, accuracy: 0.05)
    }

    func testSoftCurveReachesHighOutputEarly() {
        let curve = PressureCurve.soft
        // Soft curve should reach high output at moderate input
        let output = curve.map(0.5)
        XCTAssertGreaterThan(output, 0.6, "Soft curve should map 0.5 input to above 0.6")
    }

    func testFirmCurveRequiresHighInput() {
        let curve = PressureCurve.firm
        // Firm curve should have low output at moderate input
        let output = curve.map(0.5)
        XCTAssertLessThan(output, 0.4, "Firm curve should map 0.5 input to below 0.4")
    }

    func testPressureClamping() {
        let curve = PressureCurve.linear
        // Should clamp to [0, 1]
        XCTAssertGreaterThanOrEqual(curve.map(0.0), 0.0)
        XCTAssertLessThanOrEqual(curve.map(1.0), 1.0)
    }

    func testCurvesAreSavedPerPen() throws {
        let prefs = AppPreferences.shared
        let saved = prefs.pressureCurves
        defer { prefs.pressureCurves = saved }

        prefs.pressureCurves["test-pen"] = .soft
        let stored = try XCTUnwrap(UserDefaults.standard.data(forKey: "pressureCurves"))
        let decoded = try JSONDecoder().decode([String: PressureCurve].self, from: stored)
        XCTAssertEqual(decoded["test-pen"], .soft)
        XCTAssertEqual(prefs.pressureCurve(forPen: "test-pen"), .soft)
        XCTAssertEqual(prefs.pressureCurve(forPen: "never-seen"), .linear)
    }

    /// The editor lays out and draws; with ARTSY_DUMP_UI=1 the image is written out to look at.
    func testEditorRenders() throws {
        var curve = PressureCurve(controlPoint1: CGPoint(x: 0.2, y: 0.6), controlPoint2: CGPoint(x: 0.7, y: 0.9))
        let editor = PressureCurveEditor(curve: Binding(get: { curve }, set: { curve = $0 }))
        let hosting = NSHostingView(rootView: editor.padding(10).background(Color(nsColor: .windowBackgroundColor)))
        hosting.frame = NSRect(x: 0, y: 0, width: 160, height: 160)
        let window = NSWindow(contentRect: hosting.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = hosting
        hosting.layoutSubtreeIfNeeded()
        let rep = try XCTUnwrap(hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds))
        hosting.cacheDisplay(in: hosting.bounds, to: rep)
        if ProcessInfo.processInfo.environment["ARTSY_DUMP_UI"] == "1" {
            let url = FileManager.default.temporaryDirectory.appendingPathComponent("pressure-curve.png")
            try rep.representation(using: .png, properties: [:])?.write(to: url)
            print("UI DUMP: \(url.path)")
        }
        window.contentView = nil
    }
}
