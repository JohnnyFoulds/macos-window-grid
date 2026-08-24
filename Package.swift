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

        // Tier 9 — Warp (0x11), 3D transform (0x10), overlay compositing group (0x6e),
        //          plugin-unrestricted (0x7b), transaction alpha (0x0e) cross-process
        .executableTarget(
            name: "Probe08",
            dependencies: ["SkyLightBridge"],
            path: "Sources/Probe08"
        ),

        // Tier 10 — CAContext rendering injection via overlay compositing group
        //   SLSTransactionSetWindowCreatesOverlayCompositingGroup + SetWindowOverlayContext
        //   with CAContext.localContextWithOptions contextId — can we render on any window?
        .executableTarget(
            name: "Probe09",
            dependencies: ["SkyLightBridge"],
            path: "Sources/Probe09"
        ),

        // Tier 11 — SLSGetWindowLayerContext / SLSSetWindowLayerContext injection
        //   Get our own window's LAYER CONTEXT ID (the format SLSTransactionSetWindowOverlayContext expects)
        //   Try passing it as overlay context on foreign window
        //   Try SLSSetWindowLayerContext cross-process (direct layer hijack)
        .executableTarget(
            name: "Probe10",
            dependencies: ["SkyLightBridge"],
            path: "Sources/Probe10"
        ),

        // Tier 12 — Complete SLS layer context pipeline
        //   CreateLayerContext → SetWindowLayerContext (own) → GetWindowLayerContext readback
        //   → use returned ID as overlay context on foreign window
        .executableTarget(
            name: "Probe11",
            dependencies: ["SkyLightBridge"],
            path: "Sources/Probe11"
        ),

        // Tier 13 — CATransaction flush timing + SLSTransactionGetFencingContext
        //   Hypothesis: CAContext.contextId is valid but must be committed/flushed
        //   to CARenderServer before WindowServer knows about it
        .executableTarget(
            name: "Probe12",
            dependencies: ["SkyLightBridge"],
            path: "Sources/Probe12"
        ),

        // Tier 14 — CARemoteLayerServer + CARenderContext properties
        //   CARemoteLayerServer publishes a server-side render context
        //   that may have the right properties for overlay context use
        .executableTarget(
            name: "Probe13",
            dependencies: ["SkyLightBridge"],
            path: "Sources/Probe13"
        ),
    ]
)
