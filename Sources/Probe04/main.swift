/// Probe04 — Tier 4: Space-level transform
///
/// Reads the current Space's transform via SLSSpaceGetTransform, then
/// attempts SLSSpaceSetTransform.  A successful Space transform would scale
/// EVERYTHING on the current desktop.
///
/// Signatures corrected via disassembly:
///   SLSSpaceGetTransform: returns CGAffineTransform via x8 indirect; x2 = optional Int32* options
///   SLSSpaceSetTransform: x2 = pointer to CGAffineTransform; x3 = Int32 options
///   SLSTransactionSetSpaceTransform: same pointer convention

import AppKit
import SkyLightBridge

let ourSLS = SLSMainConnectionID()
print("SLS connection: \(ourSLS)")
print("")

// ─────────────────────────────────────────────────────────────────────────────
// Get active Space ID
// ─────────────────────────────────────────────────────────────────────────────
typealias CGSGetActiveSpaceFn = @convention(c) (Int32) -> UInt64

let getActiveSpace: CGSGetActiveSpaceFn? = {
    if let lib = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_LAZY),
       let ptr = dlsym(lib, "SLSGetActiveSpace") {
        return unsafeBitCast(ptr, to: CGSGetActiveSpaceFn.self)
    }
    if let lib = dlopen("/System/Library/Frameworks/CoreGraphics.framework/CoreGraphics", RTLD_LAZY),
       let ptr = dlsym(lib, "CGSGetActiveSpace") {
        return unsafeBitCast(ptr, to: CGSGetActiveSpaceFn.self)
    }
    return nil
}()

guard let getActiveSpace else {
    print("Neither SLSGetActiveSpace nor CGSGetActiveSpace resolved")
    exit(1)
}

let spaceID = getActiveSpace(ourSLS)
print("Active Space ID: \(spaceID)")
print("")

// ─────────────────────────────────────────────────────────────────────────────
// Read the current Space transform (corrected signature)
// ─────────────────────────────────────────────────────────────────────────────
print("=== SLSSpaceGetTransform ===")
var spaceOptions: Int32 = 0
let currentTransform = SLSSpaceGetTransform(ourSLS, spaceID, &spaceOptions)
print("transform: a=\(currentTransform.a) d=\(currentTransform.d)")
print("options=\(spaceOptions) (0x\(String(spaceOptions, radix: 16)))")
print("")

// ─────────────────────────────────────────────────────────────────────────────
// Attempt a gentle 0.9× Space transform (corrected pointer signature)
// ─────────────────────────────────────────────────────────────────────────────
print("=== SLSSpaceSetTransform (0.9×) ===")
let spaceScale = CGAffineTransform(scaleX: 0.9, y: 0.9)
let writeStatus = SLSSpaceSetTransform(ourSLS, spaceID, spaceScale, 0)
let afterSet = SLSSpaceGetTransform(ourSLS, spaceID)
print("status=\(writeStatus)  read-back a=\(afterSet.a)  [\(abs(afterSet.a - 0.9) < 0.01 ? "APPLIED ← ENTIRE SPACE SCALED!" : "no-op (silent)")]")

if abs(afterSet.a - 0.9) < 0.01 {
    print("Pausing 3 s — observe whether the entire desktop shrank...")
    Thread.sleep(forTimeInterval: 3.0)
    let resetStatus = SLSSpaceSetTransform(ourSLS, spaceID, .identity, 0)
    print("Reset: status=\(resetStatus)")
}

// ─────────────────────────────────────────────────────────────────────────────
// SLSTransactionSetSpaceTransform (corrected pointer convention)
// ─────────────────────────────────────────────────────────────────────────────
print("")
print("=== SLSTransactionSetSpaceTransform ===")
typealias TxnSpacePFn = @convention(c) (UnsafeMutableRawPointer, UInt64, UnsafePointer<CGAffineTransform>) -> Int32

if let lib = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_LAZY),
   let ptr = dlsym(lib, "SLSTransactionSetSpaceTransform"),
   let txn = SLSTransactionCreate(ourSLS) {

    let fn = unsafeBitCast(ptr, to: TxnSpacePFn.self)
    var s = spaceScale
    let r1 = withUnsafePointer(to: &s) { fn(txn, spaceID, $0) }
    let r2 = SLSTransactionCommit(txn, 1)
    print("SLSTransactionSetSpaceTransform: \(r1)")
    print("SLSTransactionCommit:            \(r2)")
    let aft = SLSSpaceGetTransform(ourSLS, spaceID)
    print("Read-back: a=\(aft.a)  [\(abs(aft.a - 0.9) < 0.01 ? "APPLIED!" : "no-op")]")

    if abs(aft.a - 0.9) < 0.01 {
        Thread.sleep(forTimeInterval: 3.0)
        if let resetTxn = SLSTransactionCreate(ourSLS) {
            var id = CGAffineTransform.identity
            let _ = withUnsafePointer(to: &id) { fn(resetTxn, spaceID, $0) }
            SLSTransactionCommit(resetTxn, 1)
            print("Reset via transaction.")
        }
    }
} else {
    print("SLSTransactionSetSpaceTransform not found or transaction create failed")
}
