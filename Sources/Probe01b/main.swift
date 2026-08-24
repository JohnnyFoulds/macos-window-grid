/// Probe01b — Tier 1b: hit-test probe
///
/// Scales our own window to 50% and draws a coordinate grid inside it.
/// When you click inside the shrunken window, we print both:
///   - the NSEvent location (AppKit coordinates, bottom-left origin)
///   - the CGEvent global position (top-left origin, full-screen space)
/// and compare to what the window server believes the click hit.
///
/// Interpretation:
///   If the printed location is in the *full-size* coordinate space of the
///   window content (e.g. clicking near the top-right corner of the shrunken
///   100×100 visual area reports ~(600,400) rather than ~(300,200)), then
///   WindowServer is routing input in UNtransformed space — we would need to
///   translate clicks ourselves.
///
///   If the reported location is ~(300,200) when you click the apparent top-right
///   of the 50%-scaled window, hit-testing *follows* the transform — input is
///   automatically correct and no translation is needed.
///
/// Also reads _kSLSUserAccessibilityReportWindowTransformKey from the window's
/// AX attributes if accessible.

import AppKit
import SkyLightBridge

// ─────────────────────────────────────────────────────────────────────────────
// Coordinate grid view — draws a labelled grid so we can tell exactly where
// a click "should" land vs. where it reports.
// ─────────────────────────────────────────────────────────────────────────────
class GridView: NSView {
    override func draw(_ dirtyRect: NSRect) {
        NSColor.systemGray.setFill()
        bounds.fill()

        let cols = 4, rows = 4
        let cellW = bounds.width  / CGFloat(cols)
        let cellH = bounds.height / CGFloat(rows)

        let colors: [NSColor] = [.systemRed, .systemBlue, .systemGreen, .systemOrange]
        for row in 0..<rows {
            for col in 0..<cols {
                let rect = NSRect(
                    x: CGFloat(col) * cellW,
                    y: CGFloat(row) * cellH,
                    width: cellW,
                    height: cellH
                )
                colors[(row + col) % colors.count].withAlphaComponent(0.5).setFill()
                rect.fill()

                let label = "(\(col),\(row))" as NSString
                label.draw(
                    at: NSPoint(x: rect.midX - 20, y: rect.midY - 8),
                    withAttributes: [
                        .foregroundColor: NSColor.white,
                        .font: NSFont.monospacedSystemFont(ofSize: 11, weight: .medium),
                    ]
                )
            }
        }
    }

    override func mouseDown(with event: NSEvent) {
        let localPt  = convert(event.locationInWindow, from: nil)
        let screenPt = window?.convertPoint(toScreen: event.locationInWindow) ?? .zero
        print("[click] local=(\(Int(localPt.x)),\(Int(localPt.y)))  " +
              "screen=(\(Int(screenPt.x)),\(Int(screenPt.y)))  " +
              "windowFrame=\(window?.frame ?? .zero)")
    }
}

// ─────────────────────────────────────────────────────────────────────────────

let app = NSApplication.shared
app.setActivationPolicy(.regular)

let contentRect = NSRect(x: 100, y: 100, width: 600, height: 400)
let window = NSWindow(
    contentRect: contentRect,
    styleMask: [.titled, .closable],
    backing: .buffered,
    defer: false
)
window.title = "Probe01b — hit-test probe (click the grid cells)"
window.contentView = GridView(frame: NSRect(origin: .zero, size: contentRect.size))
window.makeKeyAndOrderFront(nil)
app.activate(ignoringOtherApps: true)

RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.5))

let cgsConn = CGSMainConnectionID()
let slsConn = SLSMainConnectionID()
let wid     = windowID(for: window)

// Scale the window to 50% using CGS
let scaleDown  = CGAffineTransform(scaleX: 0.5, y: 0.5)
let cgsInverse = scaleDown.inverted()
let cgsStatus  = CGSSetWindowTransform(cgsConn, wid, cgsInverse)

print("Window ID: \(wid)")
print("CGSSetWindowTransform(0.5×): status=\(cgsStatus)  \(cgsStatus == 0 ? "✓" : "✗")")
print("")
print("Window is now visually 50% of its layout size.")
print("Click inside the shrunken window and observe the printed coordinates.")
print("Expected layout size: 600×400.  Shrunken visual size: ~300×200.")
print("")
print("If you click the apparent top-right corner (~300,200 visual) and the")
print("reported local point is near (600,400) → hit-testing is UNTRANSFORMED.")
print("If it reports near (300,200) → hit-testing FOLLOWS the transform (input is free).")
print("")

RunLoop.main.run()
