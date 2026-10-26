// swift-tools-version: 5.9
import PackageDescription

// The painting engine: the Metal renderers and shaders, the brushes, the stroke path,
// layers, the document and the view model. Nothing in it may import AppKit or UIKit;
// the Mac app and the iOS app each bring their own canvas view, input and chrome.
let package = Package(
    name: "ArtsyEngine",
    platforms: [.macOS(.v14), .iOS(.v17)],
    products: [
        .library(name: "ArtsyEngine", targets: ["ArtsyEngine"]),
    ],
    targets: [
        .target(
            name: "ArtsyEngine",
            path: "Sources/ArtsyEngine",
            // Spectral.h is included by Shaders.metal from its own folder; it is not a source
            exclude: ["Metal/Spectral.h"]
        ),
        // The engine's tests, the same files the Mac app's test bundle runs (a symlink to
        // ArtsyTests), so they run on an iPad simulator too; the tests that need AppKit
        // are left out here
        .testTarget(
            name: "ArtsyEngineTests",
            dependencies: ["ArtsyEngine"],
            path: "Tests/ArtsyEngineTests",
            exclude: ["Golden", "BrushLibraryTests.swift", "BrushImportTests.swift", "BrushStudioTests.swift",
                      "CanvasViewTests.swift", "CompositingTests.swift", "GuidesTests.swift", "PressureCurveTests.swift",
                      "ShellTests.swift"]
        ),
    ]
)
