/// Probe02 — Tier 2: full symbol sweep against another app's window
///
/// Finds the frontmost window of a target app (default: TextEdit) and tries
/// every known SkyLight transform entry point against it, using both our own
/// connection ID and the window's owner connection ID (Tier 3 is folded in).
///
/// Results are logged as a table:
///   symbol | our cid | owner cid | visual change?
///
/// Run with TextEdit open.  Pass a bundle ID as argv[1] to target a different app,
/// e.g.:  .build/release/Probe02 com.apple.finder

import AppKit
import ApplicationServices
import SkyLightBridge

// ─────────────────────────────────────────────────────────────────────────────
// Find the target window
// ─────────────────────────────────────────────────────────────────────────────

let targetBundleID = CommandLine.arguments.dropFirst().first ?? "com.apple.TextEdit"

// Bring the target app to front so its window is easy to find
if let targetApp = NSRunningApplication.runningApplications(withBundleIdentifier: targetBundleID).first {
    targetApp.activate(options: [])
    Thread.sleep(forTimeInterval: 0.5)
    print("Target: \(targetApp.localizedName ?? targetBundleID)  pid=\(targetApp.processIdentifier)")
} else {
    print("No running app with bundle ID: \(targetBundleID)")
    print("Please launch the target app and try again.")
    exit(1)
}

// Use CGWindowListCopyWindowInfo to find a window belonging to the target PID
guard
    let targetApp = NSRunningApplication.runningApplications(withBundleIdentifier: targetBundleID).first
else { exit(1) }

let targetPID = targetApp.processIdentifier

let windowList = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
    as? [[CFString: Any]] ?? []

guard
    let targetWindowInfo = windowList.first(where: { info in
        (info[kCGWindowOwnerPID as CFString] as? Int32) == targetPID &&
        (info[kCGWindowLayer as CFString] as? Int32 ?? 99) == 0
    }),
    let targetWID = targetWindowInfo[kCGWindowNumber as CFString] as? CGWindowID
else {
    print("Could not find an on-screen window for \(targetBundleID)")
    print("Make sure the app has at least one window visible.")
    exit(1)
}

print("Target window ID: \(targetWID)")
print("")

// ─────────────────────────────────────────────────────────────────────────────
// Connection IDs
// ─────────────────────────────────────────────────────────────────────────────

let ourCGS = CGSMainConnectionID()
let ourSLS = SLSMainConnectionID()

var ownerCID: Int32 = 0
let ownerStatus = SLSGetWindowOwner(ourSLS, targetWID, &ownerCID)
print("Our CGS cid:    \(ourCGS)")
print("Our SLS cid:    \(ourSLS)")
print("SLSGetWindowOwner: status=\(ownerStatus)  owner cid=\(ownerCID)")
if ownerCID != 0 {
    var ownerPID: pid_t = 0
    SLSConnectionGetPID(ownerCID, &ownerPID)
    print("Owner PID:      \(ownerPID)  (target PID: \(targetPID))")
}
print("")

// ─────────────────────────────────────────────────────────────────────────────
// Scale to apply
// ─────────────────────────────────────────────────────────────────────────────

// Gentle 0.8× so effect is visible but window stays on screen
let scale: CGFloat = 0.8
let transform = CGAffineTransform(scaleX: scale, y: scale)
let inverse   = transform.inverted()   // CGS wants the inverse

// ─────────────────────────────────────────────────────────────────────────────
// Sweep — each call in a helper that catches crashes via a child process would
// be ideal; for now we call them sequentially and note any SIGILL/SIGBUS crashes.
// ─────────────────────────────────────────────────────────────────────────────

struct Result { var symbol: String; var cidLabel: String; var status: Int32 }
var results: [Result] = []

func try_(_ symbol: String, cid: Int32, cidLabel: String, call: () -> Int32) {
    let status = call()
    let mark   = status == 0 ? "✓" : "✗"
    print("  \(mark) \(symbol) [\(cidLabel)]: status=\(status)")
    results.append(Result(symbol: symbol, cidLabel: cidLabel, status: status))
}

print("=== CGSSetWindowTransform ===")
try_("CGSSetWindowTransform", cid: ourCGS, cidLabel: "ourCGS")  {
    CGSSetWindowTransform(ourCGS, targetWID, inverse)
}
Thread.sleep(forTimeInterval: 1.0)
CGSSetWindowTransform(ourCGS, targetWID, .identity)

print("")
print("=== SLSSetWindowTransform (our cid) ===")
try_("SLSSetWindowTransform", cid: ourSLS, cidLabel: "ourSLS") {
    SLSSetWindowTransform(ourSLS, targetWID, transform)
}
Thread.sleep(forTimeInterval: 1.0)
SLSSetWindowTransform(ourSLS, targetWID, .identity)

if ownerCID != 0 {
    print("")
    print("=== SLSSetWindowTransform (owner cid) ===")
    try_("SLSSetWindowTransform", cid: ownerCID, cidLabel: "ownerCID") {
        SLSSetWindowTransform(ownerCID, targetWID, transform)
    }
    Thread.sleep(forTimeInterval: 1.0)
    SLSSetWindowTransform(ownerCID, targetWID, .identity)
}

print("")
print("=== SLSTransactionSetWindowTransform (our cid, corrected 5-param sig) ===")
if let txn = SLSTransactionCreate(ourSLS) {
    var t = transform
    let r = withUnsafePointer(to: &t) { SLSTransactionSetWindowTransform(txn, targetWID, 0, 0, $0) }
    let commitR = SLSTransactionCommit(txn, 1)
    print("  SLSTransactionSetWindowTransform: status=\(r)")
    print("  SLSTransactionCommit: status=\(commitR)")
    Thread.sleep(forTimeInterval: 1.0)
    if let resetTxn = SLSTransactionCreate(ourSLS) {
        var ident = CGAffineTransform.identity
        withUnsafePointer(to: &ident) { SLSTransactionSetWindowTransform(resetTxn, targetWID, 0, 0, $0) }
        SLSTransactionCommit(resetTxn, 1)
    }
} else {
    print("  SLSTransactionCreate: returned nil")
}

print("")
print("=== Summary ===")
for r in results {
    let mark = r.status == 0 ? "✓ SUCCESS" : "  failed (\(r.status))"
    print("  \(mark)  \(r.symbol) [\(r.cidLabel)]")
}
print("")
print("Check the target window visually — a status=0 with no movement is a silent no-op.")
