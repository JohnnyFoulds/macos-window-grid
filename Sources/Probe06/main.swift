/// Probe06 — Parent-child transform inheritance
///
/// Key hypothesis: SLSSetWindowParent works cross-process (confirmed status=0).
/// If transform inheritance propagates through the parent-child tree,
/// transforming OUR window (which we own) would also scale its child (TextEdit).
///
/// Test sequence:
///   1. Create our own NSWindow (we can transform this freely)
///   2. Call SLSSetWindowParent(cid, textEditWID, ourWID)
///      — parents TextEdit as a child of our window
///   3. Apply scale(0.5) to ourWID via SLSSetWindowTransform (we own it)
///   4. Check TextEdit's catenated transform via SLSGetCatenatedWindowTransform
///   5. Observe whether TextEdit visually scales
///
/// Also tests SLSSetWindowOriginRelativeToWindow cross-process positioning.

import AppKit
import SkyLightBridge

let lib = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_LAZY)!
func slsSym2<T>(_ name: String) -> T { unsafeBitCast(dlsym(lib, name)!, to: T.self) }

typealias SetParentFn = @convention(c) (Int32, CGWindowID, CGWindowID) -> Int32
let setParent: SetParentFn = slsSym2("SLSSetWindowParent")

typealias GetCatTxFn = @convention(c) (Int32, CGWindowID, UnsafeMutablePointer<CGAffineTransform>) -> Int32
let getCatTx: GetCatTxFn = slsSym2("SLSGetCatenatedWindowTransform")

let ourCID = SLSMainConnectionID()
print("CID: \(ourCID)")

// ─────────────────────────────────────────────────────────────────────────────
// AppKit setup
// ─────────────────────────────────────────────────────────────────────────────

class AppDelegate: NSObject, NSApplicationDelegate {
    var ourWindow: NSWindow!
    var teWID: CGWindowID = 0

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Create a visible window so it participates in the compositor tree
        ourWindow = NSWindow(
            contentRect: NSRect(x: 100, y: 100, width: 800, height: 600),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false)
        ourWindow.title = "Probe06 Parent"
        ourWindow.backgroundColor = .red
        ourWindow.makeKeyAndOrderFront(nil)
        let ourWID = windowID(for: ourWindow)
        print("Our window WID: \(ourWID)")

        // Find TextEdit
        guard let teApp = NSRunningApplication
            .runningApplications(withBundleIdentifier: "com.apple.TextEdit").first else {
            print("TextEdit not running — launch it and rerun"); exit(1)
        }
        teApp.activate(options: [])
        Thread.sleep(forTimeInterval: 0.5)

        let wlist = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
            as? [[CFString:Any]] ?? []
        guard let info = wlist.first(where: {
            ($0[kCGWindowOwnerPID as CFString] as? Int32) == teApp.processIdentifier &&
            ($0[kCGWindowLayer as CFString] as? Int32 ?? 99) == 0
        }), let wid = info[kCGWindowNumber as CFString] as? CGWindowID else {
            print("No TextEdit window found"); exit(1)
        }
        teWID = wid
        print("TextEdit WID: \(teWID)")
        print("")

        // Run tests after a tick so the window is composited
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            self.runTests(ourWID: ourWID)
        }
    }

    func runTests(ourWID: CGWindowID) {
        let scale = CGAffineTransform(scaleX: 0.5, y: 0.5)

        // ── Baseline ──────────────────────────────────────────────────────────
        print("=== Baseline catenated transforms ===")
        var ourCat = CGAffineTransform.identity
        var teCat = CGAffineTransform.identity
        getCatTx(ourCID, ourWID, &ourCat)
        getCatTx(ourCID, teWID, &teCat)
        print("  Our window cat: a=\(ourCat.a)")
        print("  TextEdit cat:   a=\(teCat.a)")
        print("")

        // ── Step 1: parent TextEdit under our window ──────────────────────────
        print("=== Step 1: SLSSetWindowParent(TextEdit → ourWindow) ===")
        let r1 = setParent(ourCID, teWID, ourWID)
        print("  status=\(r1)  [\(r1 == 0 ? "accepted" : "rejected")]")
        Thread.sleep(forTimeInterval: 0.5)
        var teAfterParent = CGAffineTransform.identity
        getCatTx(ourCID, teWID, &teAfterParent)
        print("  TextEdit catenated after parenting: a=\(teAfterParent.a)")
        print("")

        // ── Step 2: transform OUR window ─────────────────────────────────────
        print("=== Step 2: SLSSetWindowTransform(ourWindow, scale=0.5) ===")
        let r2 = SLSSetWindowTransform(ourCID, ourWID, scale)
        print("  status=\(r2)")
        Thread.sleep(forTimeInterval: 1.0)

        var ourAfterTx = CGAffineTransform.identity
        var teAfterParentTx = CGAffineTransform.identity
        SLSGetWindowTransform(ourCID, ourWID, &ourAfterTx)
        getCatTx(ourCID, teWID, &teAfterParentTx)
        SLSGetWindowTransform(ourCID, teWID, &teAfterParentTx)
        print("  Our window readback: a=\(ourAfterTx.a)  [\(abs(ourAfterTx.a - 0.5) < 0.01 ? "APPLIED" : "no-op")]")
        print("  TextEdit catenated:  a=\(teAfterParentTx.a)  [\(abs(teAfterParentTx.a - 0.5) < 0.01 ? "INHERITED TRANSFORM!" : "no inheritance")]")

        var teDirect = CGAffineTransform.identity
        var teCatFull = CGAffineTransform.identity
        SLSGetWindowTransform(ourCID, teWID, &teDirect)
        getCatTx(ourCID, teWID, &teCatFull)
        print("  TextEdit direct tx:  a=\(teDirect.a)")
        print("  TextEdit cat tx:     a=\(teCatFull.a)  [\(abs(teCatFull.a - 0.5) < 0.01 ? "CATENATED INHERITED!" : "no catenation")]")
        print("")
        print("(Watch screen — is TextEdit visually scaled?)")
        Thread.sleep(forTimeInterval: 3.0)

        // ── Cleanup ───────────────────────────────────────────────────────────
        SLSSetWindowTransform(ourCID, ourWID, .identity)
        setParent(ourCID, teWID, 0)
        print("Cleanup done.")
        exit(0)
    }
}

let app = NSApplication.shared
app.setActivationPolicy(.regular)
let delegate = AppDelegate()
app.delegate = delegate
app.run()
