/// Probe12 — CATransaction flush timing fix
///
/// Hypothesis: CAContext.contextId is the right format for SLSTransactionSetWindowOverlayContext,
/// but the context must be COMMITTED to CARenderServer before WS knows about it.
/// After setLayer:, the CA layer tree hasn't been submitted until CATransaction.flush().
///
/// Tests:
///   A. CAContext + setLayer: + CATransaction.flush() + SLS overlay → is contextId now valid?
///   B. Different CAContext variant: contextWithCGSConnection + flush + overlay
///   C. Disassemble bytes 94-200 of SLSTransactionSetWindowOverlayContext to find
///      full function to locate any cross-ref to validation logic
///   D. Look at SLSTransactionGetFencingContext — what does it return?

import AppKit
import QuartzCore
import SkyLightBridge

let lib = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_LAZY)!
func sym<T>(_ n: String) -> T { unsafeBitCast(dlsym(lib, n)!, to: T.self) }

typealias TxCreateFn = @convention(c) (Int32) -> UnsafeMutableRawPointer?
typealias TxCommitFn = @convention(c) (UnsafeMutableRawPointer, Int32, Int32) -> Int32
let txCreate: TxCreateFn = sym("SLSTransactionCreate")
let txCommit: TxCommitFn = sym("SLSTransactionCommit")

typealias TxOverlayGroupFn = @convention(c) (UnsafeMutableRawPointer, CGWindowID, Bool) -> Void
let setOverlayGroup: TxOverlayGroupFn = sym("SLSTransactionSetWindowCreatesOverlayCompositingGroup")
typealias TxOverlayCtxFn = @convention(c) (UnsafeMutableRawPointer, CGWindowID, UInt32) -> Void
let setOverlayCtx: TxOverlayCtxFn = sym("SLSTransactionSetWindowOverlayContext")

// SLSTransactionGetFencingContext
typealias GetFencingCtxFn = @convention(c) (UnsafeMutableRawPointer) -> UInt32
let getFencingCtx: GetFencingCtxFn = sym("SLSTransactionGetFencingContext")

let ourCID = SLSMainConnectionID()

typealias MsgSend0 = @convention(c) (AnyObject, Selector) -> AnyObject?
typealias MsgSendVoid1 = @convention(c) (AnyObject, Selector, AnyObject?) -> Void
typealias MsgSendVoid0 = @convention(c) (AnyObject, Selector) -> Void
let _ms = unsafeBitCast(dlsym(dlopen(nil, RTLD_LAZY)!, "objc_msgSend")!, to: MsgSend0.self)

func msgSend1(_ o: AnyObject, _ s: String, _ a: AnyObject?) -> AnyObject? {
    typealias F = @convention(c) (AnyObject, Selector, AnyObject?) -> AnyObject?
    return unsafeBitCast(_ms, to: F.self)(o, NSSelectorFromString(s), a)
}
func msgSendVoid1(_ o: AnyObject, _ s: String, _ a: AnyObject?) {
    unsafeBitCast(_ms, to: MsgSendVoid1.self)(o, NSSelectorFromString(s), a)
}

func flushCAAndWait() {
    // Force CA to commit pending changes to CARenderServer
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    CATransaction.commit()
    CATransaction.flush()
    // Give render server time to register the context
    Thread.sleep(forTimeInterval: 0.1)
    RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.1))
}

class AppDelegate: NSObject, NSApplicationDelegate {
    var ourWindow: NSWindow!

    func applicationDidFinishLaunching(_ n: Notification) {
        ourWindow = NSWindow(
            contentRect: NSRect(x: 50, y: 200, width: 400, height: 300),
            styleMask: [.titled, .closable], backing: .buffered, defer: false)
        ourWindow.title = "Probe12 Flush Timing"
        ourWindow.backgroundColor = .cyan
        ourWindow.makeKeyAndOrderFront(nil)
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { self.runTests() }
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

    func testOverlayWithContextId(_ ctxId: UInt32, label: String, foreignWID: CGWindowID, ownWID: CGWindowID) {
        // First try on OWN window (no ownership barrier)
        if let txn = txCreate(ourCID) {
            setOverlayGroup(txn, ownWID, true)
            setOverlayCtx(txn, ownWID, ctxId)
            let cs = txCommit(txn, 0, 0)
            print("  [\(label)] own window: commit=\(cs) \(cs == 0 ? "ACCEPTED!" : "rejected")")
        }
        Thread.sleep(forTimeInterval: 0.5)
        if let txn = txCreate(ourCID) {
            setOverlayCtx(txn, ownWID, 0); setOverlayGroup(txn, ownWID, false)
            _ = txCommit(txn, 0, 0)
        }

        // Then foreign window
        if let txn = txCreate(ourCID) {
            setOverlayGroup(txn, foreignWID, true)
            setOverlayCtx(txn, foreignWID, ctxId)
            let cs = txCommit(txn, 0, 0)
            print("  [\(label)] foreign: commit=\(cs) \(cs == 0 ? "ACCEPTED!" : "rejected")")
        }
        Thread.sleep(forTimeInterval: 0.5)
        if let txn = txCreate(ourCID) {
            setOverlayCtx(txn, foreignWID, 0); setOverlayGroup(txn, foreignWID, false)
            _ = txCommit(txn, 0, 0)
        }
    }

    func runTests() {
        guard let teWID = foreignWID() else { print("No target"); exit(1) }
        let ourWID = windowID(for: ourWindow)
        print("OurCID=\(ourCID)  OurWID=\(ourWID)  TeWID=\(teWID)\n")

        // ── A: SLSTransactionGetFencingContext ─────────────────────────────────
        // IMPORTANT: getFencingCtx marks the transaction as "fencing requested",
        // making it un-committable. We get the ID from T1, then use it in T2.
        print("=== A: SLSTransactionGetFencingContext (T1=get ID, T2=use ID) ===")
        var fencingCtxId: UInt32 = 0
        if let txnT1 = txCreate(ourCID) {
            fencingCtxId = getFencingCtx(txnT1)
            print("  getFencingContext from T1: id=\(fencingCtxId) (0x\(String(fencingCtxId, radix:16)))")
            // Don't commit T1 — it's in "fencing requested" state
            // (leak the transaction, not ideal but safe for probe)
        }
        if fencingCtxId != 0 {
            // Use the fencing context ID in a SEPARATE transaction T2
            if let txnT2 = txCreate(ourCID) {
                setOverlayGroup(txnT2, ourWID, true)
                setOverlayCtx(txnT2, ourWID, fencingCtxId)
                let cs = txCommit(txnT2, 0, 0)
                print("  T2: setOverlay(fencingCtxId=\(fencingCtxId)) on OWN: commit=\(cs) \(cs==0 ? "ACCEPTED!" : "rejected")")
            }
            Thread.sleep(forTimeInterval: 1.0)
            if let txn = txCreate(ourCID) {
                setOverlayCtx(txn, ourWID, 0); setOverlayGroup(txn, ourWID, false); _ = txCommit(txn, 0, 0)
            }

            // Fresh fencing ctx for foreign window test
            var fencingCtxId2: UInt32 = 0
            if let txnT3 = txCreate(ourCID) { fencingCtxId2 = getFencingCtx(txnT3) }
            print("  fencingCtxId2=\(fencingCtxId2)")
            if fencingCtxId2 != 0, let txnT4 = txCreate(ourCID) {
                setOverlayGroup(txnT4, teWID, true)
                setOverlayCtx(txnT4, teWID, fencingCtxId2)
                let cs = txCommit(txnT4, 0, 0)
                print("  T4: setOverlay(fencingCtxId2=\(fencingCtxId2)) on FOREIGN: commit=\(cs) \(cs==0 ? "ACCEPTED!" : "rejected")")
            }
            Thread.sleep(forTimeInterval: 2.0)
            if let txn = txCreate(ourCID) {
                setOverlayCtx(txn, teWID, 0); setOverlayGroup(txn, teWID, false); _ = txCommit(txn, 0, 0)
            }
        }
        print("")

        // ── B: CAContext + flush THEN SLS overlay (timing fix) ─────────────────
        print("=== B: CAContext + CATransaction.flush() then overlay ===")
        guard let ctxClass = NSClassFromString("CAContext") else { print("No CAContext"); exit(1) }

        // Create context and set a bright layer
        guard let ctx = msgSend1(ctxClass as AnyObject, "localContextWithOptions:", nil) else {
            print("  localContextWithOptions returned nil"); exit(1)
        }
        guard let cidObj = ctx.value(forKey: "contextId") as? UInt32 else {
            print("  contextId not readable"); exit(1)
        }
        print("  CAContext.contextId=\(cidObj) (0x\(String(cidObj, radix:16)))")

        let layer = CALayer()
        layer.backgroundColor = CGColor(red: 1, green: 0, blue: 0, alpha: 1)
        layer.frame = CGRect(x: 0, y: 0, width: 2000, height: 2000)
        let tl = CATextLayer()
        tl.string = "FLUSH TIMING TEST"; tl.frame = CGRect(x: 50, y: 50, width: 600, height: 80)
        tl.fontSize = 36; tl.foregroundColor = .white
        layer.addSublayer(tl)
        msgSendVoid1(ctx, "setLayer:", layer)

        // FLUSH and wait
        print("  Flushing CATransaction and waiting 500ms for render server registration...")
        flushCAAndWait()
        Thread.sleep(forTimeInterval: 0.5)

        print("  Now calling SLS overlay transaction...")
        testOverlayWithContextId(cidObj, label: "CACtx+flush", foreignWID: teWID, ownWID: ourWID)
        print("")

        // ── C: Force multiple run loop cycles ──────────────────────────────────
        print("=== C: CAContext + 2s run loop wait ===")
        guard let ctx2 = msgSend1(ctxClass as AnyObject, "localContextWithOptions:", nil),
              let cidObj2 = ctx2.value(forKey: "contextId") as? UInt32 else { print("  failed"); exit(1) }
        print("  New CAContext.contextId=\(cidObj2)")

        let layer2 = CALayer()
        layer2.backgroundColor = CGColor(red: 0, green: 1, blue: 0, alpha: 1)
        layer2.frame = CGRect(x: 0, y: 0, width: 2000, height: 2000)
        msgSendVoid1(ctx2, "setLayer:", layer2)
        CATransaction.flush()
        Thread.sleep(forTimeInterval: 2.0)
        print("  Waited 2s — trying overlay now:")
        testOverlayWithContextId(cidObj2, label: "2s-wait", foreignWID: teWID, ownWID: ourWID)
        print("")

        // ── D: What happens with 0x6e alone (no context) ─────────────────────
        print("=== D: SetOverlayGroup(true) only, no context ID ===")
        if let txn = txCreate(ourCID) {
            setOverlayGroup(txn, teWID, true)
            let cs = txCommit(txn, 0, 0)
            print("  setOverlayGroup only (no ctx) on foreign: commit=\(cs)")
        }
        Thread.sleep(forTimeInterval: 2.0)
        print("  (Did foreign window visually change with just overlay group?)")
        if let txn = txCreate(ourCID) {
            setOverlayGroup(txn, teWID, false)
            _ = txCommit(txn, 0, 0)
        }
        print("")

        print("=== Summary ===")
        print("If 'ACCEPTED' + visual injection: overlay rendering confirmed")
        exit(0)
    }
}

let app = NSApplication.shared
app.setActivationPolicy(.regular)
let delegate = AppDelegate()
app.delegate = delegate
app.run()
