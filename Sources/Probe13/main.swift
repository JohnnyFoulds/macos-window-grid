/// Probe13 — CARemoteLayerServer as overlay context
///
/// Architecture insight: CARemoteLayerServer publishes a CA layer tree that can
/// be consumed by other processes/the WindowServer via its contextId.
/// This is the "server-side render context" architecture used for cross-process
/// CA rendering (e.g., UIProcess rendering into AppProcess via CALayerHost).
///
/// Hypothesis: SLSTransactionSetWindowOverlayContext expects a render context
/// that is "server-published" (accessible to the WindowServer), like a
/// CARemoteLayerServer.contextId. Our previous CAContext.contextId had:
///   - displayId=0 (not bound to a display)
///   - level=-24395776 (strange)
///   - opts=0x0 (no flags)
/// CARemoteLayerServer may create a context with proper server-side properties.
///
/// Also tests CALayerHost to see what contextId it requires and if creating one
/// linked to a foreign window's context works.

import AppKit
import QuartzCore
import SkyLightBridge

let lib = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_LAZY)!
let qcLib = dlopen("/System/Library/Frameworks/QuartzCore.framework/QuartzCore", RTLD_LAZY)!
func sym<T>(_ n: String) -> T { unsafeBitCast(dlsym(lib, n)!, to: T.self) }
func qcSym<T>(_ n: String) -> T { unsafeBitCast(dlsym(qcLib, n)!, to: T.self) }

typealias TxCreateFn = @convention(c) (Int32) -> UnsafeMutableRawPointer?
typealias TxCommitFn = @convention(c) (UnsafeMutableRawPointer, Int32, Int32) -> Int32
let txCreate: TxCreateFn = sym("SLSTransactionCreate")
let txCommit: TxCommitFn = sym("SLSTransactionCommit")
typealias TxOverlayGroupFn = @convention(c) (UnsafeMutableRawPointer, CGWindowID, Bool) -> Void
let setOverlayGroup: TxOverlayGroupFn = sym("SLSTransactionSetWindowCreatesOverlayCompositingGroup")
typealias TxOverlayCtxFn = @convention(c) (UnsafeMutableRawPointer, CGWindowID, UInt32) -> Void
let setOverlayCtx: TxOverlayCtxFn = sym("SLSTransactionSetWindowOverlayContext")

typealias RenderCtxByIdFn = @convention(c) (UInt32) -> UnsafeMutableRawPointer?
let renderCtxById: RenderCtxByIdFn = qcSym("CARenderContextById")
typealias RenderCtxGetIdFn = @convention(c) (UnsafeMutableRawPointer) -> UInt32
let renderCtxGetId: RenderCtxGetIdFn = qcSym("CARenderContextGetId")
typealias RenderCtxGetOptsFn = @convention(c) (UnsafeMutableRawPointer) -> UInt64
let renderCtxGetOpts: RenderCtxGetOptsFn = qcSym("CARenderContextGetOptions")
typealias RenderCtxGetLevelFn = @convention(c) (UnsafeMutableRawPointer) -> Int32
let renderCtxGetLevel: RenderCtxGetLevelFn = qcSym("CARenderContextGetLevel")
typealias RenderCtxGetDisplayIdFn = @convention(c) (UnsafeMutableRawPointer) -> UInt32
let renderCtxGetDisplayId: RenderCtxGetDisplayIdFn = qcSym("CARenderContextGetDisplayId")
typealias RenderCtxGetHostCtxIdFn = @convention(c) (UnsafeMutableRawPointer) -> UInt32
let renderCtxGetHostCtxId: RenderCtxGetHostCtxIdFn = qcSym("CARenderContextGetHostContextId")
typealias RenderCtxGetProcIdFn = @convention(c) (UnsafeMutableRawPointer) -> Int32
let renderCtxGetProcId: RenderCtxGetProcIdFn = qcSym("CARenderContextGetProcessId")

let ourCID = SLSMainConnectionID()

typealias MsgSend0 = @convention(c) (AnyObject, Selector) -> AnyObject?
typealias MsgSendVoid1 = @convention(c) (AnyObject, Selector, AnyObject?) -> Void
let _ms = unsafeBitCast(dlsym(dlopen(nil, RTLD_LAZY)!, "objc_msgSend")!, to: MsgSend0.self)
func msgSend0(_ o: AnyObject, _ s: String) -> AnyObject? {
    unsafeBitCast(_ms, to: MsgSend0.self)(o, NSSelectorFromString(s))
}
func msgSend1(_ o: AnyObject, _ s: String, _ a: AnyObject?) -> AnyObject? {
    typealias F = @convention(c) (AnyObject, Selector, AnyObject?) -> AnyObject?
    return unsafeBitCast(_ms, to: F.self)(o, NSSelectorFromString(s), a)
}
func msgSendVoid1(_ o: AnyObject, _ s: String, _ a: AnyObject?) {
    unsafeBitCast(_ms, to: MsgSendVoid1.self)(o, NSSelectorFromString(s), a)
}

func inspectRC(_ id: UInt32, label: String) {
    guard let rc = renderCtxById(id) else { print("  [\(label)] id=\(id) → NOT FOUND"); return }
    let proc = renderCtxGetProcId(rc)
    let opts = renderCtxGetOpts(rc)
    let level = renderCtxGetLevel(rc)
    let hostId = renderCtxGetHostCtxId(rc)
    let dispId = renderCtxGetDisplayId(rc)
    print("  [\(label)] id=\(id) procId=\(proc) opts=0x\(String(opts,radix:16)) level=\(level) hostCtxId=\(hostId) displayId=\(dispId)")
}

func tryOverlay(_ ctxId: UInt32, _ wid: CGWindowID, label: String) {
    if let txn = txCreate(ourCID) {
        setOverlayGroup(txn, wid, true)
        setOverlayCtx(txn, wid, ctxId)
        let cs = txCommit(txn, 0, 0)
        print("  [\(label)] ctxId=\(ctxId) WID=\(wid): commit=\(cs) \(cs==0 ? "*** ACCEPTED ***" : "status=\(cs)")")
    }
    Thread.sleep(forTimeInterval: 1.0)
    if let txn = txCreate(ourCID) {
        setOverlayCtx(txn, wid, 0); setOverlayGroup(txn, wid, false); _ = txCommit(txn, 0, 0)
    }
}

class AppDelegate: NSObject, NSApplicationDelegate {
    var ourWindow: NSWindow!

    func applicationDidFinishLaunching(_ n: Notification) {
        ourWindow = NSWindow(
            contentRect: NSRect(x:50, y:200, width:400, height:300),
            styleMask: [.titled, .closable], backing: .buffered, defer: false)
        ourWindow.title = "Probe13 Remote Layer"
        ourWindow.backgroundColor = .cyan
        ourWindow.makeKeyAndOrderFront(nil)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { self.runTests() }
    }

    func foreignWID() -> CGWindowID? {
        for bid in ["com.apple.Notes", "com.google.Chrome", "com.apple.TextEdit"] {
            if let app = NSRunningApplication.runningApplications(withBundleIdentifier: bid).first {
                app.activate(options: [])
                Thread.sleep(forTimeInterval: 0.3)
                let wlist = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[CFString:Any]] ?? []
                if let info = wlist.first(where: {
                    ($0[kCGWindowOwnerPID as CFString] as? Int32) == app.processIdentifier &&
                    ($0[kCGWindowLayer as CFString] as? Int32 ?? 99) == 0
                }), let wid = info[kCGWindowNumber as CFString] as? CGWindowID {
                    print("Target: \(app.localizedName ?? bid) WID=\(wid)"); return wid
                }
            }
        }
        return nil
    }

    func runTests() {
        guard let teWID = foreignWID() else { exit(1) }
        let ourWID = windowID(for: ourWindow)
        print("OurCID=\(ourCID)  OurWID=\(ourWID)  TeWID=\(teWID)\n")

        // ── A: Inspect our own window's render context ─────────────────────────
        print("=== A: Inspect own window's CAContext render context (AppKit vs CLI) ===")
        if let ctxClass = NSClassFromString("CAContext"),
           let ctx = msgSend1(ctxClass as AnyObject, "localContextWithOptions:", nil),
           let cidObj = ctx.value(forKey: "contextId") as? UInt32 {
            print("  CAContext.contextId=\(cidObj)")
            let layer = CALayer(); layer.backgroundColor = CGColor(red:1,green:0,blue:0,alpha:1)
            layer.frame = ourWindow.contentView!.bounds
            msgSendVoid1(ctx, "setLayer:", layer)
            CATransaction.flush()
            Thread.sleep(forTimeInterval: 0.2)
            inspectRC(cidObj, label: "CAContext-AppKit")
            tryOverlay(cidObj, ourWID, label: "CACtx own")
            tryOverlay(cidObj, teWID, label: "CACtx foreign")
        }
        print("")

        // ── B: CARemoteLayerServer (AppKit) ────────────────────────────────────
        print("=== B: CARemoteLayerServer (AppKit process) ===")
        guard let serverClass = NSClassFromString("CARemoteLayerServer") else {
            print("  CARemoteLayerServer not found"); return
        }
        // CARemoteLayerServer is typically created by UIKit/AppKit internally.
        // Try +serverWithKey: or just +new or +alloc+init
        var server: AnyObject? = nil
        server = msgSend0(serverClass as AnyObject, "new")
        if server == nil { server = msgSend1(serverClass as AnyObject, "serverWithKey:", "probe13" as AnyObject) }
        if let srv = server, let ctxId = srv.value(forKey: "contextId") as? UInt32 {
            print("  CARemoteLayerServer.contextId=\(ctxId)")
            let layer = CALayer(); layer.backgroundColor = CGColor(red:0,green:1,blue:0,alpha:1)
            layer.frame = CGRect(x:0,y:0,width:500,height:500)
            let tl = CATextLayer()
            tl.string = "REMOTE LAYER INJECTION"; tl.frame = CGRect(x:10,y:10,width:450,height:60)
            tl.fontSize = 28; tl.foregroundColor = .white
            layer.addSublayer(tl)
            msgSendVoid1(srv, "setLayer:", layer)
            CATransaction.flush()
            Thread.sleep(forTimeInterval: 0.3)
            inspectRC(ctxId, label: "RemoteLayerServer")
            tryOverlay(ctxId, ourWID, label: "RLS own")
            tryOverlay(ctxId, teWID, label: "RLS foreign")
        } else {
            // Try to get contextId differently
            print("  CARemoteLayerServer.new → \(server.map({"\($0)"}) ?? "nil"), trying contextId via KVC...")
            if let srv = server {
                print("  srv properties: \(srv.description)")
                // Some versions may use 'identifier' instead
                let ids = ["contextId", "identifier", "serverIdentifier", "renderContextId"]
                for key in ids {
                    let val = try? srv.value(forKey: key)
                    print("  \(key) = \(val.map({"\($0)"}) ?? "nil")")
                }
            }
        }
        print("")

        // ── C: CALayerHost to see what contextId format it expects ─────────────
        print("=== C: CALayerHost inspection ===")
        guard let hostClass = NSClassFromString("CALayerHost") else {
            print("  CALayerHost not found"); return
        }
        // CALayerHost is a layer subclass; create one and check what contextId it uses
        if let hostLayer = msgSend0(hostClass as AnyObject, "new") {
            print("  CALayerHost created: \(hostLayer)")
            let keys = ["contextId", "contextID", "hostContextId"]
            for key in keys {
                if let val = try? hostLayer.value(forKey: key) {
                    print("  \(key)=\(val)")
                }
            }
            // Set contextId using our own CAContext's ID and see if it connects
            if let ctxClass2 = NSClassFromString("CAContext"),
               let ctx2 = msgSend1(ctxClass2 as AnyObject, "localContextWithOptions:", nil),
               let cid2 = ctx2.value(forKey: "contextId") as? UInt32 {
                let cid2obj = NSNumber(value: cid2)
                (try? hostLayer.setValue(cid2obj, forKey: "contextId")) ?? {}()
                CATransaction.flush()
                Thread.sleep(forTimeInterval: 0.2)
                if let val = try? hostLayer.value(forKey: "contextId") {
                    print("  After set contextId: \(val)")
                }
                // Use the CALayerHost's contextId as overlay context
                if let hCtxId = (try? hostLayer.value(forKey: "contextId")) as? UInt32, hCtxId != 0 {
                    inspectRC(hCtxId, label: "LayerHost")
                }
            }
        }
        print("")

        print("=== Done ===")
        exit(0)
    }
}

let app = NSApplication.shared
app.setActivationPolicy(.regular)
let delegate = AppDelegate()
app.delegate = delegate
app.run()
