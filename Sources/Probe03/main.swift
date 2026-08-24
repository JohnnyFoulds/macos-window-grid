/// Probe03 — Tier 3: owner connection-ID deep dive
///
/// The central hypothesis: CGS / SLS may check "does the provided cid own this
/// wid" rather than "is the *caller* this cid".  If so, passing the target
/// window's owner connection ID might bypass the ownership check.
///
/// This probe:
///   1. Lists all on-screen windows and their owner connection IDs.
///   2. For each target window, tries SLSSetWindowTransform with the owner cid.
///   3. Also tries CGSGetConnectionIDForPSN if it resolves.
///   4. Reads Dock.app's connection ID specifically, since Dock is the
///      universal owner — if we can get Dock's cid, we may be able to
///      transform anything.
///
/// Expected: passing the owner cid probably still fails (the check is almost
/// certainly on who is calling, not what cid is in the argument), but this is
/// the key untested idea and must be verified empirically.

import AppKit
import SkyLightBridge

let ourSLS = SLSMainConnectionID()
print("Our SLS connection: \(ourSLS)")
print("")

// ─────────────────────────────────────────────────────────────────────────────
// List all on-screen windows with their owner connection IDs
// ─────────────────────────────────────────────────────────────────────────────
print("=== On-screen windows and their owner connection IDs ===")
let windowList = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
    as? [[CFString: Any]] ?? []

for info in windowList {
    guard
        let wid  = info[kCGWindowNumber as CFString] as? CGWindowID,
        let pid  = info[kCGWindowOwnerPID as CFString] as? Int32,
        let name = info[kCGWindowOwnerName as CFString] as? String,
        let layer = info[kCGWindowLayer as CFString] as? Int32,
        layer == 0  // normal windows only
    else { continue }

    var ownerCID: Int32 = 0
    let s = SLSGetWindowOwner(ourSLS, wid, &ownerCID)
    print("  wid=\(wid)  pid=\(pid)  cid=\(ownerCID)  status=\(s)  \"\(name)\"")
}
print("")

// ─────────────────────────────────────────────────────────────────────────────
// Find Dock.app's connection ID
// ─────────────────────────────────────────────────────────────────────────────
print("=== Dock.app connection ID ===")
if let dockApp = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.dock").first {
    let dockPID = dockApp.processIdentifier
    print("Dock PID: \(dockPID)")

    // Walk the window list to find a Dock-owned window
    for info in windowList {
        guard
            let wid = info[kCGWindowNumber as CFString] as? CGWindowID,
            let pid = info[kCGWindowOwnerPID as CFString] as? Int32,
            pid == dockPID
        else { continue }

        var dockCID: Int32 = 0
        let s = SLSGetWindowOwner(ourSLS, wid, &dockCID)
        if dockCID != 0 {
            print("Dock cid via wid=\(wid): \(dockCID)  status=\(s)")
            break
        }
    }
} else {
    print("Dock not found in running applications")
}
print("")

// ─────────────────────────────────────────────────────────────────────────────
// Try CGSGetConnectionIDForPSN if it exists
// ─────────────────────────────────────────────────────────────────────────────
print("=== CGSGetConnectionIDForPSN ===")
typealias CGSGetConnectionIDForPSNFn = @convention(c) (Int32, UnsafeRawPointer, UnsafeMutablePointer<Int32>) -> Int32
if let cgsFn: CGSGetConnectionIDForPSNFn = {
    guard let lib = dlopen("/System/Library/Frameworks/CoreGraphics.framework/CoreGraphics", RTLD_LAZY),
          let ptr = dlsym(lib, "CGSGetConnectionIDForPSN") else { return nil }
    return unsafeBitCast(ptr, to: CGSGetConnectionIDForPSNFn.self)
}() {
    print("CGSGetConnectionIDForPSN resolved ✓")
    // This takes a PSN (ProcessSerialNumber) — deprecated but may work.
    // PSN for target process would require GetProcessForPID → out of scope here.
    // Just confirm the symbol exists.
} else {
    print("CGSGetConnectionIDForPSN not found in CoreGraphics")
}
print("")

// ─────────────────────────────────────────────────────────────────────────────
// Pick the first non-Dock non-SystemUI normal window and try with its owner cid
// ─────────────────────────────────────────────────────────────────────────────
let excludedOwners = ["Dock", "SystemUIServer", "WindowServer", "Control Center", "Notification Center"]

if let targetInfo = windowList.first(where: { info in
    guard
        let layer = info[kCGWindowLayer as CFString] as? Int32,
        let name  = info[kCGWindowOwnerName as CFString] as? String,
        layer == 0,
        !excludedOwners.contains(name)
    else { return false }
    return true
}),
let targetWID  = targetInfo[kCGWindowNumber as CFString] as? CGWindowID,
let targetName = targetInfo[kCGWindowOwnerName as CFString] as? String {

    var ownerCID: Int32 = 0
    SLSGetWindowOwner(ourSLS, targetWID, &ownerCID)
    print("=== Transform target: \"\(targetName)\" wid=\(targetWID) ownerCID=\(ownerCID) ===")

    let scale = CGAffineTransform(scaleX: 0.8, y: 0.8)

    print("Trying SLSSetWindowTransform with OUR cid (\(ourSLS)):")
    let r1 = SLSSetWindowTransform(ourSLS, targetWID, scale)
    print("  status=\(r1)  \(r1 == 0 ? "✓" : "✗")")
    Thread.sleep(forTimeInterval: 1.5)
    SLSSetWindowTransform(ourSLS, targetWID, .identity)

    if ownerCID != 0 && ownerCID != ourSLS {
        print("Trying SLSSetWindowTransform with OWNER cid (\(ownerCID)):")
        let r2 = SLSSetWindowTransform(ownerCID, targetWID, scale)
        print("  status=\(r2)  \(r2 == 0 ? "✓ (OWNER CID WORKED!)" : "✗")")
        Thread.sleep(forTimeInterval: 1.5)
        SLSSetWindowTransform(ownerCID, targetWID, .identity)
    }
} else {
    print("No suitable target window found — open a third-party app and rerun.")
}
