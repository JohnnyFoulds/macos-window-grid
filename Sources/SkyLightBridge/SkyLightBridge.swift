/// SkyLightBridge — private SkyLight / CGS symbol declarations for probing
/// window compositor transforms on macOS.
///
/// Symbol declarations are derived from:
///   - NotificationNanny PrivateWindowAPI.swift (MIT)
///     https://github.com/3rd-Musketeer/notification-nanny-focused-screen
///   - Live `dyld_info -exports` run against SkyLight on macOS 26.6.2 arm64
///
/// CGS / SkyLight ownership model:
///   An app may only transform windows it owns.  Dock.app is the universal
///   owner.  CGSSetUniversalOwner requires a private Apple entitlement.
///   This file exposes every known transform entry point so each can be tested
///   independently — a shotgun approach is deliberately avoided so we know
///   exactly which call succeeds or fails.

import AppKit
import ApplicationServices

// ---------------------------------------------------------------------------
// MARK: - CGS (CoreGraphicsServices) — public-ish private API
// ---------------------------------------------------------------------------

@_silgen_name("CGSMainConnectionID")
public func CGSMainConnectionID() -> Int32

@_silgen_name("_AXUIElementGetWindow")
public func _AXUIElementGetWindow(
    _ element: AXUIElement,
    _ windowID: UnsafeMutablePointer<CGWindowID>
) -> AXError

@_silgen_name("CGSSetWindowTransform")
@discardableResult
public func CGSSetWindowTransform(
    _ connection: Int32,
    _ windowID: CGWindowID,
    _ transform: CGAffineTransform
) -> Int32

@_silgen_name("CGSGetWindowTransform")
@discardableResult
public func CGSGetWindowTransform(
    _ connection: Int32,
    _ windowID: CGWindowID,
    _ transform: UnsafeMutablePointer<CGAffineTransform>
) -> Int32

@_silgen_name("CGSSetWindowAlpha")
@discardableResult
public func CGSSetWindowAlpha(
    _ connection: Int32,
    _ windowID: CGWindowID,
    _ alpha: Float
) -> Int32

// ---------------------------------------------------------------------------
// MARK: - SkyLight — resolved dynamically (avoid link-time failures on new OS)
// ---------------------------------------------------------------------------

private let _skyLight: UnsafeMutableRawPointer? =
    dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_LAZY)

/// Resolve a SkyLight symbol by name. Returns nil and logs if not found.
public func slsSym<T>(_ name: String) -> T? {
    guard let lib = _skyLight else {
        print("[SkyLightBridge] SkyLight.framework not loaded")
        return nil
    }
    guard let ptr = dlsym(lib, name) else {
        print("[SkyLightBridge] symbol not found: \(name)")
        return nil
    }
    return unsafeBitCast(ptr, to: T.self)
}

// ---------------------------------------------------------------------------
// MARK: - SLS connection helpers
// ---------------------------------------------------------------------------

public func SLSMainConnectionID() -> Int32 {
    typealias Fn = @convention(c) () -> Int32
    return (slsSym("SLSMainConnectionID") as Fn?)?(  ) ?? 0
}

/// Returns the connection ID that owns the given window.
/// This is SIP-safe (read-only query).
@discardableResult
public func SLSGetWindowOwner(
    _ connection: Int32,
    _ windowID: CGWindowID,
    _ ownerOut: UnsafeMutablePointer<Int32>
) -> Int32 {
    typealias Fn = @convention(c) (Int32, CGWindowID, UnsafeMutablePointer<Int32>) -> Int32
    return (slsSym("SLSGetWindowOwner") as Fn?)?(connection, windowID, ownerOut) ?? -1
}

/// Maps a SLS connection ID to its owning PID.
public func SLSConnectionGetPID(_ connection: Int32, _ pidOut: UnsafeMutablePointer<pid_t>) -> Int32 {
    typealias Fn = @convention(c) (Int32, UnsafeMutablePointer<pid_t>) -> Int32
    return (slsSym("SLSConnectionGetPID") as Fn?)?(connection, pidOut) ?? -1
}

// ---------------------------------------------------------------------------
// MARK: - Per-window transform calls (each tested in isolation)
// ---------------------------------------------------------------------------

/// _SLSSetWindowTransform — the primary target from prior literature.
@discardableResult
public func SLSSetWindowTransform(
    _ connection: Int32,
    _ windowID: CGWindowID,
    _ transform: CGAffineTransform
) -> Int32 {
    typealias Fn = @convention(c) (Int32, CGWindowID, CGAffineTransform) -> Int32
    return (slsSym("SLSSetWindowTransform") as Fn?)?(connection, windowID, transform) ?? -1
}

/// _SLSSetWindowTransforms — plural: takes a C array of window IDs and transforms.
/// Signature inferred from SLSSetWindowTransformsAtPlacement disassembly.
@discardableResult
public func SLSSetWindowTransforms(
    _ connection: Int32,
    _ windowIDs: UnsafePointer<CGWindowID>,
    _ transforms: UnsafePointer<CGAffineTransform>,
    _ count: Int32
) -> Int32 {
    typealias Fn = @convention(c) (Int32, UnsafePointer<CGWindowID>, UnsafePointer<CGAffineTransform>, Int32) -> Int32
    return (slsSym("SLSSetWindowTransforms") as Fn?)?(connection, windowIDs, transforms, count) ?? -1
}

/// _SLSGetWindowTransform — read back to verify a set succeeded.
@discardableResult
public func SLSGetWindowTransform(
    _ connection: Int32,
    _ windowID: CGWindowID,
    _ transformOut: UnsafeMutablePointer<CGAffineTransform>
) -> Int32 {
    typealias Fn = @convention(c) (Int32, CGWindowID, UnsafeMutablePointer<CGAffineTransform>) -> Int32
    return (slsSym("SLSGetWindowTransform") as Fn?)?(connection, windowID, transformOut) ?? -1
}

/// _SLSGetCatenatedWindowTransform — the cumulative/composed transform.
@discardableResult
public func SLSGetCatenatedWindowTransform(
    _ connection: Int32,
    _ windowID: CGWindowID,
    _ transformOut: UnsafeMutablePointer<CGAffineTransform>
) -> Int32 {
    typealias Fn = @convention(c) (Int32, CGWindowID, UnsafeMutablePointer<CGAffineTransform>) -> Int32
    return (slsSym("SLSGetCatenatedWindowTransform") as Fn?)?(connection, windowID, transformOut) ?? -1
}

// ---------------------------------------------------------------------------
// MARK: - Transaction variants
// ---------------------------------------------------------------------------

/// Transaction API — use opaque pointers (not AnyObject) to avoid ARC issues.
/// Returns raw pointer from SLSTransactionCreate; caller must not retain/release.
public func SLSTransactionCreate(_ connection: Int32) -> UnsafeMutableRawPointer? {
    typealias Fn = @convention(c) (Int32) -> UnsafeMutableRawPointer?
    return (slsSym("SLSTransactionCreate") as Fn?)?(connection)
}

@discardableResult
public func SLSTransactionCommit(_ transaction: UnsafeMutableRawPointer, _ sync: Int32) -> Int32 {
    typealias Fn = @convention(c) (UnsafeMutableRawPointer, Int32) -> Int32
    return (slsSym("SLSTransactionCommit") as Fn?)?(transaction, sync) ?? -1
}

/// Disassembly-verified signature:
/// x0 = transaction, x1 = windowID, x2 = Int32 unknown, x3 = Int32 unknown,
/// x4 = UnsafePointer<CGAffineTransform> (48-byte struct, by reference)
/// Note: return value is a SkyLight internal token, not a standard OSStatus.
@discardableResult
public func SLSTransactionSetWindowTransform(
    _ transaction: UnsafeMutableRawPointer,
    _ windowID: CGWindowID,
    _ param2: Int32,
    _ param3: Int32,
    _ transform: UnsafePointer<CGAffineTransform>
) -> Int32 {
    typealias Fn = @convention(c) (UnsafeMutableRawPointer, CGWindowID, Int32, Int32,
                                   UnsafePointer<CGAffineTransform>) -> Int32
    return (slsSym("SLSTransactionSetWindowTransform") as Fn?)?(
        transaction, windowID, param2, param3, transform) ?? -1
}

// ---------------------------------------------------------------------------
// MARK: - Space-level transforms
// ---------------------------------------------------------------------------

/// Disassembly-verified: returns CGAffineTransform via x8 (indirect result).
/// x2 = optional Int32* for options output (pass nil if not needed).
public func SLSSpaceGetTransform(
    _ connection: Int32,
    _ spaceID: UInt64,
    _ optionsOut: UnsafeMutablePointer<Int32>? = nil
) -> CGAffineTransform {
    typealias Fn = @convention(c) (Int32, UInt64, UnsafeMutablePointer<Int32>?) -> CGAffineTransform
    return (slsSym("SLSSpaceGetTransform") as Fn?)?(connection, spaceID, optionsOut) ?? .identity
}

/// Disassembly-verified: x2 = UnsafePointer<CGAffineTransform>; x3 = Int32 options.
/// Returns standard OSStatus (0 = sent, though server may still ignore if not universal-owner).
@discardableResult
public func SLSSpaceSetTransform(
    _ connection: Int32,
    _ spaceID: UInt64,
    _ transform: CGAffineTransform,
    _ options: Int32 = 0
) -> Int32 {
    typealias Fn = @convention(c) (Int32, UInt64, UnsafePointer<CGAffineTransform>, Int32) -> Int32
    var t = transform
    return withUnsafePointer(to: &t) { ptr in
        (slsSym("SLSSpaceSetTransform") as Fn?)?(connection, spaceID, ptr, options) ?? -1
    }
}

// ---------------------------------------------------------------------------
// MARK: - Utilities
// ---------------------------------------------------------------------------

/// Returns the CGWindowID for the window sitting beneath the given NSWindow.
/// Uses the NSWindow's windowNumber, which equals CGWindowID on AppKit.
public func windowID(for window: NSWindow) -> CGWindowID {
    CGWindowID(window.windowNumber)
}

/// Returns the CGWindowID for an AXUIElement (e.g. from AppleEvents / Accessibility).
public func windowID(for element: AXUIElement) -> CGWindowID? {
    var wid: CGWindowID = 0
    guard _AXUIElementGetWindow(element, &wid) == .success, wid != 0 else { return nil }
    return wid
}

/// Dump all discovered SkyLight transform symbols and whether they resolve.
public func dumpSymbolResolution() {
    let symbols = [
        "SLSMainConnectionID",
        "SLSGetWindowOwner",
        "SLSConnectionGetPID",
        "SLSSetWindowTransform",
        "SLSSetWindowTransforms",
        "SLSSetWindowTransformAtPlacement",
        "SLSSetWindowTransformsAtPlacement",
        "SLSGetWindowTransform",
        "SLSGetWindowTransformAtPlacement",
        "SLSGetCatenatedWindowTransform",
        "SLSTransactionCreate",
        "SLSTransactionCommit",
        "SLSTransactionSetWindowTransform",
        "SLSTransactionSetWindowTransform3D",
        "SLSTransactionSetSpaceTransform",
        "SLSSpaceGetTransform",
        "SLSSpaceSetTransform",
        "SLSPackagesSetWindowDragTransform",
        "SLSPackagesRemoveWindowDragTransform",
        "SLSStructuralRegionSetChildRegionTransform",
    ]
    print("=== SkyLight symbol resolution on \(ProcessInfo.processInfo.operatingSystemVersionString) ===")
    for sym in symbols {
        let found = _skyLight.flatMap { dlsym($0, sym) } != nil
        print("  \(found ? "✓" : "✗")  \(sym)")
    }
}
