/// Probe01Own — Tier 1 control test
///
/// Opens our own NSWindow and applies CGSSetWindowTransform / SLSSetWindowTransform
/// to it.  This MUST succeed — if our own window cannot be scaled, the harness is
/// broken and all later negative results are meaningless.
///
/// Also dumps the full SkyLight symbol resolution table for reference.
///
/// What to look for:
///   - The window should visually shrink to half size.
///   - Both CGS and SLS status codes are printed; at least one must be 0.
///   - The read-back transform from SLSGetWindowTransform should match what was set.
///
/// Run for ~10 s then Ctrl-C.  Grant Accessibility permission if prompted
/// (needed later; not required for this probe itself).

import AppKit
import SkyLightBridge

// Create a minimal NSApplication so we can have an NSWindow
let app = NSApplication.shared
app.setActivationPolicy(.regular)

// Build a plain window
let window = NSWindow(
    contentRect: NSRect(x: 200, y: 200, width: 600, height: 400),
    styleMask: [.titled, .closable, .resizable],
    backing: .buffered,
    defer: false
)
window.title = "Probe01Own — transform control test"
window.backgroundColor = .systemBlue
window.makeKeyAndOrderFront(nil)
app.activate(ignoringOtherApps: true)

// Give the window server a moment to composite the window
RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.5))

// ── Symbol resolution table ──────────────────────────────────────────────────
dumpSymbolResolution()
print("")

// ── Connection IDs ───────────────────────────────────────────────────────────
let cgsConn = CGSMainConnectionID()
let slsConn = SLSMainConnectionID()
let wid     = windowID(for: window)

print("CGS connection:  \(cgsConn)")
print("SLS connection:  \(slsConn)")
print("Window ID:       \(wid)")
print("")

// ── Read baseline transform ──────────────────────────────────────────────────
var baseline = CGAffineTransform.identity
let readStatus = SLSGetWindowTransform(slsConn, wid, &baseline)
print("SLSGetWindowTransform (before): status=\(readStatus)  transform=\(baseline)")
print("")

// ── Apply 0.5× scale via CGS ─────────────────────────────────────────────────
// CGS transforms are *inverse*: passing scale(2) renders at 0.5 visual size.
// We invert explicitly so the code reads as intent.
let scaleDown = CGAffineTransform(scaleX: 0.5, y: 0.5)
let cgsInverse = scaleDown.inverted()  // CGS expects inverse matrix

let cgsStatus = CGSSetWindowTransform(cgsConn, wid, cgsInverse)
print("CGSSetWindowTransform(0.5×):  status=\(cgsStatus)  \(cgsStatus == 0 ? "✓ SUCCESS" : "✗ FAILED")")

var afterCGS = CGAffineTransform.identity
let readAfterCGS = SLSGetWindowTransform(slsConn, wid, &afterCGS)
print("SLSGetWindowTransform (after CGS): status=\(readAfterCGS)  transform=\(afterCGS)")
print("")

// ── Reset and try SLS ────────────────────────────────────────────────────────
RunLoop.main.run(until: Date(timeIntervalSinceNow: 2.0))  // pause so you can see the CGS result

let resetStatus = CGSSetWindowTransform(cgsConn, wid, .identity)
print("CGSSetWindowTransform(identity reset): status=\(resetStatus)")

RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.5))

let slsStatus = SLSSetWindowTransform(slsConn, wid, scaleDown)
print("SLSSetWindowTransform(0.5×):  status=\(slsStatus)  \(slsStatus == 0 ? "✓ SUCCESS" : "✗ FAILED")")

var afterSLS = CGAffineTransform.identity
let readAfterSLS = SLSGetWindowTransform(slsConn, wid, &afterSLS)
print("SLSGetWindowTransform (after SLS): status=\(readAfterSLS)  transform=\(afterSLS)")
print("")

// ── Catenated transform ──────────────────────────────────────────────────────
var catenated = CGAffineTransform.identity
let catStatus = SLSGetCatenatedWindowTransform(slsConn, wid, &catenated)
print("SLSGetCatenatedWindowTransform: status=\(catStatus)  transform=\(catenated)")
print("")

print("Window is scaled — observe visually.  Ctrl-C to exit.")
RunLoop.main.run()
