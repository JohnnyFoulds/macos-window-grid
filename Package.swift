// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "macos-window-grid",
    platforms: [.macOS(.v13)],
    targets: [
        // Shared library: SkyLight symbol declarations and helpers
        .target(
            name: "SkyLightBridge",
            path: "Sources/SkyLightBridge"
        ),

        // Tier 1 — control: transform our own NSWindow
        .executableTarget(
            name: "Probe01Own",
            dependencies: ["SkyLightBridge"],
            path: "Sources/Probe01Own"
        ),

        // Tier 1b — hit-test: does WindowServer route input to transformed coords?
        .executableTarget(
            name: "Probe01b",
            dependencies: ["SkyLightBridge"],
            path: "Sources/Probe01b"
        ),

        // Tier 2 — full symbol sweep against another app's window
        .executableTarget(
            name: "Probe02",
            dependencies: ["SkyLightBridge"],
            path: "Sources/Probe02"
        ),

        // Tier 3 — owner connection-ID experiment
        .executableTarget(
            name: "Probe03",
            dependencies: ["SkyLightBridge"],
            path: "Sources/Probe03"
        ),

        // Tier 4 — Space-level transform
        .executableTarget(
            name: "Probe04",
            dependencies: ["SkyLightBridge"],
            path: "Sources/Probe04"
        ),

        // Tier 6 — SLSSetUniversalOwner + conn flag poke + cross-process alpha
        .executableTarget(
            name: "Probe05",
            dependencies: ["SkyLightBridge"],
            path: "Sources/Probe05"
        ),

        // Tier 7 — parent-child transform inheritance
        .executableTarget(
            name: "Probe06",
            dependencies: ["SkyLightBridge"],
            path: "Sources/Probe06"
        ),

        // Tier 8 — Packages drag-space pipeline: AddWindowToDraggingSpace + SetWindowDragTransform
        .executableTarget(
            name: "Probe07",
            dependencies: ["SkyLightBridge"],
            path: "Sources/Probe07"
        ),
    ]
)
