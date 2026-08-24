/// Probe05 — SLSSetUniversalOwner + conn-flag poke + cross-process alpha
///
/// Three attack vectors in one probe:
///
/// A) Direct call to SLSSetUniversalOwner(ourCID)
///    - Sends msgid=0x1513 to WindowServer; server checks entitlement
///    - Error code reveals whether check is strict or soft
///    - With ad-hoc signing of com.apple.private.skylight.universal-owner,
///      WindowServer might accept it → transforms become unrestricted
///
/// B) Conn-flag poke: read CGSConnectionByID(cid)[0x1d], set to 1 directly
///    - SLSSetUniversalOwner sets this byte at offset 0x1d of the conn struct
///      after the server validates the entitlement
///    - If we set it directly without server validation, and if
///      CGSWindowGetMappedImpl checks this flag before looking up foreign windows,
///      then subsequent transform mach messages may carry the "owner confirmed" bit
///    - Empirical test: transform foreign window BEFORE and AFTER poke
///
/// C) Cross-process alpha test
///    - SLSSetWindowAlpha is a different kind of manipulation
///    - If it works cross-process but transforms don't, the ownership model is
///      transform-specific → look for the non-transform path
///    - If it also fails cross-process, the ownership model is universal

import AppKit
import SkyLightBridge

// ─────────────────────────────────────────────────────────────────────────────
// Helpers
// ─────────────────────────────────────────────────────────────────────────────

func slsSymUnsafe<T>(_ name: String) -> T {
    let lib = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_LAZY)!
    let ptr = dlsym(lib, name)!
    return unsafeBitCast(ptr, to: T.self)
}

let ourCID = SLSMainConnectionID()
print("Our SLS connection: \(ourCID)")
print("")

// ─────────────────────────────────────────────────────────────────────────────
// Find a foreign window to test against
// ─────────────────────────────────────────────────────────────────────────────

let targetBundleID = CommandLine.arguments.dropFirst().first ?? "com.apple.TextEdit"
guard let targetApp = NSRunningApplication.runningApplications(withBundleIdentifier: targetBundleID).first else {
    print("No running app: \(targetBundleID) — launch it and retry")
    exit(1)
}
targetApp.activate(options: [])
Thread.sleep(forTimeInterval: 0.5)

let windowList = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
    as? [[CFString: Any]] ?? []
guard let info = windowList.first(where: {
        ($0[kCGWindowOwnerPID as CFString] as? Int32) == targetApp.processIdentifier &&
        ($0[kCGWindowLayer as CFString] as? Int32 ?? 99) == 0
    }),
    let targetWID = info[kCGWindowNumber as CFString] as? CGWindowID
else {
    print("No window found for \(targetBundleID)")
    exit(1)
}
print("Target: \(targetApp.localizedName ?? targetBundleID)  wid=\(targetWID)")
print("")

// ─────────────────────────────────────────────────────────────────────────────
// Helper: try transform and report read-back
// ─────────────────────────────────────────────────────────────────────────────

func testTransform(label: String) {
    let scale = CGAffineTransform(scaleX: 0.5, y: 0.5)
    let r = SLSSetWindowTransform(ourCID, targetWID, scale)
    Thread.sleep(forTimeInterval: 0.5)
    var readback = CGAffineTransform.identity
    SLSGetWindowTransform(ourCID, targetWID, &readback)
    let applied = abs(readback.a - 0.5) < 0.01
    print("  \(label): status=\(r)  readback.a=\(readback.a)  [\(applied ? "APPLIED ← BREAKTHROUGH!" : "no-op")]")
    SLSSetWindowTransform(ourCID, targetWID, .identity)
}

// ─────────────────────────────────────────────────────────────────────────────
// Baseline: transform before anything special
// ─────────────────────────────────────────────────────────────────────────────
print("=== Baseline (no special setup) ===")
testTransform(label: "SLSSetWindowTransform baseline")
print("")

// ─────────────────────────────────────────────────────────────────────────────
// Attack A: SLSSetUniversalOwner direct call
// ─────────────────────────────────────────────────────────────────────────────
print("=== Attack A: SLSSetUniversalOwner(\(ourCID)) ===")
typealias SetUOFn = @convention(c) (Int32) -> Int32
let setUO: SetUOFn = slsSymUnsafe("SLSSetUniversalOwner")
let uoStatus = setUO(ourCID)
print("  SLSSetUniversalOwner status: \(uoStatus)  (0=success, -308=no entitlement, other=?)")
if uoStatus == 0 {
    print("  !!! SERVER ACCEPTED — we may now be universal owner !!!")
}
testTransform(label: "transform after SLSSetUniversalOwner")
print("")

// ─────────────────────────────────────────────────────────────────────────────
// Attack B: Read conn struct and poke [+0x1d] = 1 directly
// ─────────────────────────────────────────────────────────────────────────────
print("=== Attack B: CGSConnectionByID poke ===")
// CGSConnectionByID is an internal SkyLight function at fixed address 0x18ea123c8
// It takes (Int32 cid) and returns UnsafeMutableRawPointer (the CGSConnection ObjC object)
typealias ConnByIDFn = @convention(c) (Int32) -> UnsafeMutableRawPointer?
let connByID: ConnByIDFn = unsafeBitCast(
    UnsafeRawPointer(bitPattern: 0x18ea123c8)!, to: ConnByIDFn.self)
if let connPtr = connByID(ourCID) {
    let bytePtr = connPtr.advanced(by: 0x1d).assumingMemoryBound(to: UInt8.self)
    let before = bytePtr.pointee
    print("  conn ptr: \(connPtr)  [+0x1d] before poke: \(before)")
    bytePtr.pointee = 1
    let after = bytePtr.pointee
    print("  [+0x1d] after poke: \(after)")
    testTransform(label: "transform after conn-flag poke")
    // Reset
    bytePtr.pointee = before
    print("  (flag reset to \(before))")
} else {
    print("  CGSConnectionByID returned nil — address may have changed on this OS build")
    // Try via dlsym instead
    if let lib = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_LAZY),
       let ptr = dlsym(lib, "CGSConnectionByID") {
        let fn = unsafeBitCast(ptr, to: ConnByIDFn.self)
        if let connPtr2 = fn(ourCID) {
            let bytePtr2 = connPtr2.advanced(by: 0x1d).assumingMemoryBound(to: UInt8.self)
            let before2 = bytePtr2.pointee
            print("  (via dlsym) conn ptr: \(connPtr2)  [+0x1d] before poke: \(before2)")
            bytePtr2.pointee = 1
            testTransform(label: "transform after conn-flag poke (dlsym)")
            bytePtr2.pointee = before2
        } else {
            print("  (via dlsym) CGSConnectionByID also returned nil")
        }
    } else {
        print("  CGSConnectionByID not found via dlsym either")
    }
}
print("")

// ─────────────────────────────────────────────────────────────────────────────
// Attack C: Cross-process SLSSetWindowAlpha — does ownership model apply to all?
// ─────────────────────────────────────────────────────────────────────────────
print("=== Attack C: SLSSetWindowAlpha cross-process ===")
typealias SetAlphaFn = @convention(c) (Int32, CGWindowID, Float) -> Int32
let setAlpha: SetAlphaFn = slsSymUnsafe("SLSSetWindowAlpha")
let alphaStatus = setAlpha(ourCID, targetWID, 0.3)
Thread.sleep(forTimeInterval: 1.0)
// Read it back
typealias GetAlphaFn = @convention(c) (Int32, CGWindowID, UnsafeMutablePointer<Float>) -> Int32
let getAlpha: GetAlphaFn = slsSymUnsafe("SLSGetWindowAlpha")
var alphaVal: Float = -1
getAlpha(ourCID, targetWID, &alphaVal)
let alphaApplied = abs(alphaVal - 0.3) < 0.05
print("  SLSSetWindowAlpha(0.3): status=\(alphaStatus)  readback=\(alphaVal)")
print("  [\(alphaApplied ? "APPLIED — alpha respects different rules than transform!" : "no-op — ownership model is universal")]")
// Reset
setAlpha(ourCID, targetWID, 1.0)

// ─────────────────────────────────────────────────────────────────────────────
// Attack D: SLSSetWindowLevel cross-process
// ─────────────────────────────────────────────────────────────────────────────
print("")
print("=== Attack D: SLSSetWindowLevel cross-process ===")
typealias GetLevelFn = @convention(c) (Int32, CGWindowID, UnsafeMutablePointer<Int32>) -> Int32
typealias SetLevelFn = @convention(c) (Int32, CGWindowID, Int32) -> Int32
let getLevel: GetLevelFn = slsSymUnsafe("SLSGetWindowLevel")
let setLevel: SetLevelFn = slsSymUnsafe("SLSSetWindowLevel")
var origLevel: Int32 = 0
let getLevelStatus = getLevel(ourCID, targetWID, &origLevel)
print("  original level: \(origLevel)  (getLevelStatus=\(getLevelStatus))")
let setLevelStatus = setLevel(ourCID, targetWID, origLevel + 1)
Thread.sleep(forTimeInterval: 0.5)
var newLevel: Int32 = 0
getLevel(ourCID, targetWID, &newLevel)
let levelApplied = newLevel != origLevel
print("  setLevel status=\(setLevelStatus)  readback=\(newLevel)  [\(levelApplied ? "APPLIED!" : "no-op")]")
setLevel(ourCID, targetWID, origLevel)

// ─────────────────────────────────────────────────────────────────────────────
// Attack E: SLSSetWindowActive + SLSSetWindowParent (different manipulation types)
// ─────────────────────────────────────────────────────────────────────────────
print("")
print("=== Attack E: SLSSetWindowActive cross-process ===")
typealias SetActiveFn = @convention(c) (Int32, CGWindowID, Bool) -> Int32
let setActive: SetActiveFn = slsSymUnsafe("SLSSetWindowActive")
let activeStatus = setActive(ourCID, targetWID, true)
print("  SLSSetWindowActive: status=\(activeStatus)  [\(activeStatus == 0 ? "accepted" : "rejected")]")

print("")
print("=== Summary ===")
print("Attack A (SLSSetUniversalOwner): status=\(uoStatus)")
print("Attack C (SLSSetWindowAlpha):    status=\(alphaStatus), readback=\(alphaVal)")
print("Attack D (SLSSetWindowLevel):    status=\(setLevelStatus), readback=\(newLevel)/orig=\(origLevel)")
print("Attack E (SLSSetWindowActive):   status=\(activeStatus)")
