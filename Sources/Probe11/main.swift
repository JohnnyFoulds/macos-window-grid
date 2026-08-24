/// Probe11 — Complete SLS layer context pipeline
///
/// The correct sequence for overlay context rendering:
///   1. SLSCreateLayerContext(cid, &id1, &id2) → create a new layer context
///   2. SLSSetWindowLayerContext(cid, ourWID, id1 or id2) → attach to our window
///   3. SLSGetWindowLayerContext(cid, ourWID) → read back the actual assigned ID
///   4. That ID is what SLSTransactionSetWindowOverlayContext expects
///   5. Use it as overlay context on a FOREIGN window
///
/// Also tests:
///   - Whether we can set foreign window's layer context cross-process
///   - What happens if we set BOTH windows to the same layer context
///   - SLSTransactionSetWindowTransform on OWN window while overlay is active

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

typealias TxTransformFn = @convention(c) (UnsafeMutableRawPointer, CGWindowID, UnsafePointer<CGAffineTransform>) -> Void
let setTxTransform: TxTransformFn = sym("SLSTransactionSetWindowTransform")

typealias GetLayerCtxFn = @convention(c) (Int32, CGWindowID) -> UInt32
let getLayerCtx: GetLayerCtxFn = sym("SLSGetWindowLayerContext")

typealias SetLayerCtxFn = @convention(c) (Int32, CGWindowID, UInt32) -> Int32
let setLayerCtx: SetLayerCtxFn = sym("SLSSetWindowLayerContext")

typealias CreateLayerCtxFn = @convention(c) (Int32, UnsafeMutablePointer<Int32>, UnsafeMutablePointer<Int32>) -> Int32
let createLayerCtx: CreateLayerCtxFn = sym("SLSCreateLayerContext")

typealias GetWinTransformFn = @convention(c) (Int32, CGWindowID, UnsafeMutablePointer<CGAffineTransform>) -> Void
let getWinTransform: GetWinTransformFn = sym("SLSGetWindowTransform")

let ourCID = SLSMainConnectionID()

typealias MsgSend0 = @convention(c) (AnyObject, Selector) -> AnyObject?
typealias MsgSendVoid1 = @convention(c) (AnyObject, Selector, AnyObject?) -> Void
let _ms = unsafeBitCast(dlsym(dlopen(nil, RTLD_LAZY)!, "objc_msgSend")!, to: MsgSend0.self)
func msgSend1(_ o: AnyObject, _ s: String, _ a: AnyObject?) -> AnyObject? {
    typealias F = @convention(c) (AnyObject, Selector, AnyObject?) -> AnyObject?
    return unsafeBitCast(_ms, to: F.self)(o, NSSelectorFromString(s), a)
}
func msgSendVoid1(_ o: AnyObject, _ s: String, _ a: AnyObject?) {
    unsafeBitCast(_ms, to: MsgSendVoid1.self)(o, NSSelectorFromString(s), a)
}

class AppDelegate: NSObject, NSApplicationDelegate {
    var ourWindow: NSWindow!

    func applicationDidFinishLaunching(_ n: Notification) {
        ourWindow = NSWindow(
            contentRect: NSRect(x: 50, y: 200, width: 400, height: 300),
            styleMask: [.titled, .closable], backing: .buffered, defer: false)
        ourWindow.title = "Probe11 Layer Pipeline"
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
        guard let teWID = foreignWID() else { print("No target"); exit(1) }
        let ourWID = windowID(for: ourWindow)
        print("OurCID=\(ourCID)  OurWID=\(ourWID)  TeWID=\(teWID)\n")

        // ── Step 1: Create a layer context ────────────────────────────────────
        print("=== Step 1: SLSCreateLayerContext ===")
        var id1: Int32 = 0, id2: Int32 = 0
        let createStatus = createLayerCtx(ourCID, &id1, &id2)
        print("  status=\(createStatus) id1=\(id1) (0x\(String(UInt32(bitPattern:id1), radix:16))) id2=\(id2)")
        let id1u = UInt32(bitPattern: id1)
        let id2u = UInt32(id2)

        // ── Step 2: Attach layer context to OWN window ────────────────────────
        print("\n=== Step 2: SLSSetWindowLayerContext on OWN window ===")
        var setR1 = setLayerCtx(ourCID, ourWID, id2u)
        print("  SetWindowLayerContext(ourWID, id2=\(id2u)): status=\(setR1)")
        var setR2 = setLayerCtx(ourCID, ourWID, id1u)
        print("  SetWindowLayerContext(ourWID, id1u=\(id1u)): status=\(setR2)")

        // ── Step 3: Read back layer context ──────────────────────────────────
        print("\n=== Step 3: SLSGetWindowLayerContext readback ===")
        let readback = getLayerCtx(ourCID, ourWID)
        let readbackForeign = getLayerCtx(ourCID, teWID)
        print("  GetWindowLayerContext(ourWID)=\(readback) (expected non-0 if set)")
        print("  GetWindowLayerContext(teWID)=\(readbackForeign)")

        // ── Step 4: Use readback ID as overlay context on foreign window ───────
        print("\n=== Step 4: Use layer context ID as overlay on FOREIGN window ===")
        let ctxIdToUse: UInt32 = readback != 0 ? readback : id2u
        print("  Using ctxId=\(ctxIdToUse) (source: \(readback != 0 ? "readback" : "id2"))")

        // Prime a visible layer
        if let ctxClass = NSClassFromString("CAContext"),
           let ctx = msgSend1(ctxClass as AnyObject, "localContextWithOptions:", nil) {
            let layer = CALayer()
            layer.backgroundColor = CGColor(red: 1, green: 0, blue: 0, alpha: 1)
            layer.frame = CGRect(x: 0, y: 0, width: 2000, height: 2000)
            let tl = CATextLayer()
            tl.string = "SLS LAYER CTX INJECTION"
            tl.frame = CGRect(x: 50, y: 50, width: 600, height: 60)
            tl.fontSize = 32; tl.foregroundColor = .white
            layer.addSublayer(tl)
            msgSendVoid1(ctx, "setLayer:", layer)
        }

        if let txn = txCreate(ourCID) {
            setOverlayGroup(txn, teWID, true)
            setOverlayCtx(txn, teWID, ctxIdToUse)
            let cs = txCommit(txn, 0, 0)
            print("  setOverlay(ctxId=\(ctxIdToUse)) on foreign WID=\(teWID): commit=\(cs)")
            print("  [\(cs == 0 ? "ACCEPTED — check screen!" : "rejected cs=\(cs)")]")
        }
        Thread.sleep(forTimeInterval: 4.0)
        print("  *** Did 'SLS LAYER CTX INJECTION' appear on the Notes/foreign window? ***")
        Thread.sleep(forTimeInterval: 3.0)
        if let txn = txCreate(ourCID) {
            setOverlayCtx(txn, teWID, 0)
            setOverlayGroup(txn, teWID, false)
            _ = txCommit(txn, 0, 0)
        }
        print("")

        // ── Step 5: Try SLSSetWindowLayerContext cross-process ─────────────────
        print("=== Step 5: SLSSetWindowLayerContext cross-process (direct layer hijack) ===")
        let xpR = setLayerCtx(ourCID, teWID, ctxIdToUse)
        print("  SetWindowLayerContext(teWID=\(teWID), ctxId=\(ctxIdToUse)): status=\(xpR)")
        print("  [\(xpR == 0 ? "ACCEPTED — foreign window's layer context changed!" : "rejected status=\(xpR)")]")
        if xpR == 0 {
            Thread.sleep(forTimeInterval: 4.0)
            print("  *** Did foreign window content change? ***")
            // Restore
            if readbackForeign != 0 {
                _ = setLayerCtx(ourCID, teWID, readbackForeign)
            }
        }
        print("")

        // ── Step 6: Overlay on OWN window (sanity: does ctxId work on own?) ────
        print("=== Step 6: setOverlay with ctxId=\(ctxIdToUse) on OWN window ===")
        if let txn = txCreate(ourCID) {
            setOverlayGroup(txn, ourWID, true)
            setOverlayCtx(txn, ourWID, ctxIdToUse)
            let cs = txCommit(txn, 0, 0)
            print("  setOverlay on OWN window: commit=\(cs)")
            print("  [\(cs == 0 ? "ACCEPTED — layer ctx ID is valid!" : "rejected")]")
        }
        Thread.sleep(forTimeInterval: 3.0)
        if let txn = txCreate(ourCID) {
            setOverlayCtx(txn, ourWID, 0)
            setOverlayGroup(txn, ourWID, false)
            _ = txCommit(txn, 0, 0)
        }
        print("")

        print("=== Summary ===")
        print("CreateLayerContext: id1=\(id1u) id2=\(id2u)")
        print("SetWindowLayerContext own (id2): \(setR1)  (id1): \(setR2)")
        print("GetWindowLayerContext own: \(readback)  foreign: \(readbackForeign)")
        exit(0)
    }
}

let app = NSApplication.shared
app.setActivationPolicy(.regular)
let delegate = AppDelegate()
app.delegate = delegate
app.run()
