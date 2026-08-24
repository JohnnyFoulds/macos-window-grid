# Findings — Phase 1 (Approach A: GPU/Compositor Transform)

## System
- macOS 26.6.2 (Tahoe), arm64, SIP enabled
- Swift 6.3.3, CommandLineTools only
- SkyLight load address: `0x18ea0d000`

---

## Tier 1 — Control: transform our own window

| Call | Connection | Status | Read-back a= | Visual |
| --- | --- | --- | --- | --- |
| `CGSSetWindowTransform(scale(2), own)` | ourCGS | 0 ✓ | 2.0 (applied) | Window rendered at 50% ✓ |
| `SLSSetWindowTransform(scale(0.5), own)` | ourSLS | 0 ✓ | 0.5 (applied) | Window rendered at 50% ✓ |
| `SLSTransactionSetWindowTransform(0.8×, own)` | ourSLS | non-zero† | 0.8 (applied) | Window rendered at 80% ✓ |

†Non-zero status from transaction calls is a SkyLight internal token, not an error code. Read-back
is the reliable success indicator.

**Notes:**
- CGS takes the **inverse** transform (pass `scale(2)` to render at 50%).
- SLS takes the **direct** scale transform.
- AppKit `window.frame` is **unchanged** by CGS transform — it is purely a compositor effect.

### Calling convention corrections (from disassembly)

`SLSSetWindowTransform` actual signature:
```swift
// x2 = UnsafePointer<CGAffineTransform> (48-byte struct, passed by ref per AAPCS64)
@convention(c) (Int32, CGWindowID, UnsafePointer<CGAffineTransform>) -> Int32
```

`SLSTransactionSetWindowTransform` actual signature (disassembled at 0x18EAE8154):
```swift
// 5 parameters: x2 and x3 are Int32 unknowns; x4 = pointer to transform
@convention(c) (UnsafeMutableRawPointer, CGWindowID, Int32, Int32, UnsafePointer<CGAffineTransform>) -> Int32
```

`SLSSpaceGetTransform` actual signature (disassembled at 0x18ED0373C):
```swift
// Returns CGAffineTransform via x8 (indirect result); x2 = optional options output
@convention(c) (Int32, UInt64, UnsafeMutablePointer<Int32>?) -> CGAffineTransform
```

`SLSSpaceSetTransform` actual signature (disassembled at 0x18ED03AB8):
```swift
// x2 = pointer to CGAffineTransform; x3 = Int32 options
@convention(c) (Int32, UInt64, UnsafePointer<CGAffineTransform>, Int32) -> Int32
```

---

## Tier 1b — Hit-test: does input follow the transform?

| Observation | Result |
| --- | --- |
| AppKit `window.frame` after transform | **Unchanged** (transform is compositor-only) |
| Synthetic click at center of VISUAL (scaled) window | **Not received** |
| Hit-testing coordinate space | **Original (untransformed)** |

**Conclusion:** `CGSSetWindowTransform` scales the rendered pixels but leaves the hit-test
region at the original size and position. A click at visual coordinates does not land inside
the window. Even if ownership were bypassed, input coordinates would need to be translated
back to untransformed space.

This is **different from what the Mission Control bug demonstrated**. The interactive
thumbnail behaviour in Mission Control is almost certainly using `SLSSpaceSetTransform`
(Space-level transform) which may affect hit-testing differently, not per-window transforms.

---

## Tier 2 — Full symbol sweep against Chrome's window

| Symbol | Our CID | Owner CID | Read-back changed? |
| --- | --- | --- | --- |
| `CGSSetWindowTransform` | status=0 | n/a | NO — silent no-op |
| `SLSSetWindowTransform` | status=0 | status=268435459 ✗ | NO — silent no-op |
| `SLSTransactionSetWindowTransform` | non-zero status | n/a | NO — not applied |

**Key finding:** All per-window transform calls return status=0 or non-zero (see Tier 5 for
explanation) but the transform is **never applied** to windows we don't own.
The WindowServer accepts the mach message and silently discards it.

Passing the **owner's connection ID** (Chrome's CID = 587779) returns status=268435459 —
an actual error, not a silent no-op. The ownership check is on the *sending* mach port,
not the CID argument.

---

## Tier 3 — Owner connection-ID experiment

| Hypothesis | Result |
| --- | --- |
| Passing owner CID bypasses ownership check | ✗ — returns error 268435459 |
| Dock.app CID obtained | ✓ (via `SLSGetWindowOwner` on a Dock window) |

---

## Tier 4 — Space-level transform

| Call | Status | Read-back changed? |
| --- | --- | --- |
| `SLSSpaceGetTransform` | 0 ✓ | n/a — read: identity + options=0x1000004 |
| `SLSSpaceSetTransform(0.9×)` | 0 | NO — silent no-op |
| `SLSTransactionSetSpaceTransform` | non-zero | NO — not applied |

The Space transform has the same ownership restriction as per-window transforms.
All attempted values for the `options` parameter (0, 1, 2, 3, 0x1000004) produce
identical results.

---

## Tier 5 — Disassembly

### Ownership check mechanism

Disassembly of `SLSSetWindowTransformAtPlacement` at offset `0x337D34`:

```
bl    transform_is_valid            // validate the transform matrix
cbz   w0, return_1000               // if invalid → return kCGErrorIllegalArgument

bl    SLSMainConnection             // server-side connection
bl    CGSWindowGetMappedImpl        // look up window impl (returns NULL if not owner)
// if found: set flag, synchronize CA transaction

bl    CGSGetConnectionPortById      // get our mach port
// build mach message msgid=0x7551
bl    voucher_mach_msg_set
bl    mach_msg                      // SEND to WindowServer
```

The ownership check is **server-side** — WindowServer enforces it by checking whether
the sending mach port corresponds to a connection with `universal-owner` permission or
ownership of the target window.

### Dock.app's entitlement

```
com.apple.private.skylight.universal-owner = true
```

This entitlement grants WindowServer permission to apply transform requests from that
connection to **any** window. It is an Apple-private entitlement only available to
Apple-signed binaries.

### Private entitlement cluster found in SkyLight strings

```
com.apple.private.skylight.universal-owner
com.apple.private.skylight.privacy-indicator
com.apple.private.skylight.assessment-agent
com.apple.private.skylight.universal-control
```

### `SLSSetUniversalOwner` (offset 0x0034878C, mach msgid 0x1513)

Sends msgid=0x1513 to WindowServer. Server checks `universal-owner` entitlement on the
sending port. If OK, sends back confirmation and client sets `conn[0x1d] = 1`. Without
the entitlement, returns status=1002.

Attempt: ad-hoc signing with `com.apple.private.skylight.universal-owner` embedded via
`codesign -s -`. AMFI kills the process at launch (exit 137 = SIGKILL) on SIP-enabled macOS
before `main()` executes.

---

## Phase 2 — Exhaustive bypass attempts (Probe05–Probe07)

### Attack A: SLSSetUniversalOwner direct call
**Result:** status=1002 (server rejected — no entitlement)

### Attack B: Poke conn[0x1d] directly  
`CGSConnectionByID(cid)` at absolute address `0x18ea123c8`. Set byte at offset 0x1d to 1.  
**Result:** No effect — ownership check is server-side via mach port identity, not this flag.

### Attack C: SLSSetWindowAlpha cross-process
**Result:** Blocked — same ownership model as transforms.

### Attack D: SLSSetWindowLevel cross-process  
**Result:** WORKS — z-ordering changes are intentionally more permissive in WindowServer.
Level changes applied and read back correctly. Z-ordering only, not rendering transforms.

### Attack E: SLSSetWindowParent cross-process  
**Result:** WORKS (status=0) — foreign window can be parented to our window.
BUT: parent-child transform inheritance does NOT propagate through the compositor.
`SLSGetCatenatedWindowTransform` on child reads identity even when parent is scaled 0.5×.

### Attack F: Packages drag-space pipeline (Probe07)

**Disassembly confirmation:** Both `SLSPackagesAddWindowToDraggingSpace` (msgid=0x75E8)
and `SLSPackagesSetWindowDragTransform` (msgid=0x76C9) have NO `CGSWindowGetMappedImpl`
call client-side.

`SLSPackagesAddWindowToDraggingSpace` includes WID in mach message body.  
`SLSPackagesSetWindowDragTransform` does NOT include WID in body — applies to drag space globally.

**Empirical test:**
```
addToDragSpace(ourCID, teWID)          → mach msg sent (no crash)
setDragTransform(ourCID, ..., 0.5×)   → mach msg sent (no crash)
SLSGetWindowTransform readback         → a=1.0 (no change)
Visual observation                     → no visual change on screen
```

**Even on our own window:** drag transform does not affect `SLSGetWindowTransform` readback.
The drag transform pipeline operates on a **separate compositing layer** used exclusively during
window drag animations (Exposé/Mission Control drag gestures), not the persistent compositor
window transform. The transform is not reflected in `SLSGetWindowTransform`.

### Attack G: SLSStructuralRegionSetChildRegionTransform (Probe07)

**Disassembly confirmation:** No `CGSWindowGetMappedImpl` call. Validates transform then
sends msgid=0x76C0 with the region_id embedded in the message body.

**Empirical test (WID passed as regionID):**
```
structuralRegionTransform(ourCID, teWID, &scale0.5)   → status=0 (accepted)
SLSGetWindowTransform readback                          → a=1.0 (no change)
structuralRegionTransform(ourCID, ourWID, &scale0.5)   → status=0 (accepted, own window)
SLSGetWindowTransform readback on own window            → a=1.0 (no change)
```

**Conclusion:** The "structural region transform" is a property of the accessibility/hit-test
tree, not the rendering compositor. It is accepted for both own and foreign windows (no ownership
check server-side for this message), but does not affect visual rendering.

---

## Complete bypass attempt table

| Approach | Result |
| --- | --- |
| `CGSSetWindowTransform` cross-process | Blocked (server-side ownership) |
| `SLSSetWindowTransform` cross-process | Blocked (server-side ownership) |
| `SLSTransactionSetWindowTransform` cross-process | Blocked |
| `SLSSpaceSetTransform` | Blocked |
| `SLSSetUniversalOwner` without entitlement | status=1002 |
| Ad-hoc signing with private entitlement | AMFI kills (exit 137) |
| Poke conn[0x1d] directly | No server-side effect |
| `SLSSetWindowAlpha` cross-process | Blocked |
| `SLSSetWindowLevel` cross-process | **WORKS** (z-order only) |
| `SLSSetWindowParent` cross-process | **WORKS** (no transform inheritance) |
| Parent-child transform inheritance | No inheritance in compositor |
| `SLSPackagesAddWindowToDraggingSpace` cross-process | Mach msg accepted, no compositor change |
| `SLSPackagesSetWindowDragTransform` cross-process | Drag layer only, not persistent compositor |
| `SLSStructuralRegionSetChildRegionTransform` cross-process | status=0 but accessibility tree only, not rendering |

---

## Summary — What works, what doesn't

| Capability | Status | Notes |
| --- | --- | --- |
| Transform our own window | ✓ Works | All variants; read-back confirms |
| Transform another app's window | ✗ Blocked | Server-side; silent no-op |
| Transform an entire Space | ✗ Blocked | Same server-side restriction |
| Read back window transform | ✓ Works | `SLSGetWindowTransform` |
| Read space transform | ✓ Works | `SLSSpaceGetTransform` |
| Hit-testing follows transform | ✗ No | Purely visual; input at original coords |
| Add foreign window to drag space | ✓ Mach msg accepted | Drag layer only, no persistent effect |
| Structural region transform cross-process | ✓ Mach msg accepted | Accessibility tree only |

---

## Phase 3 — Transaction opcodes + DYLD injection audit (Probe08)

### Complete transaction opcode table (confirmed via disassembly)

| Opcode | Function | Server-side ownership check |
| --- | --- | --- |
| 0x08 | `SLSTransactionSetWindowProperty` | Unknown (not tested) |
| 0x0e | `SLSTransactionSetWindowSystemAlpha` | YES — alpha blocked cross-process |
| 0x0f | `SLSTransactionSetWindowTransform` | YES — blocked (Probe02+) |
| 0x10 | `SLSTransactionSetWindowTransform3D` | YES — blocked cross-process |
| 0x11 | `SLSTransactionSetWindowWarp` | YES — blocked cross-process (or no readback fn) |
| 0x1d | `SLSTransactionSetSpaceShape` | n/a (space-level) |
| 0x1e | `SLSTransactionSetSpaceAbsoluteLevel` | n/a (space-level) |
| 0x6b | `SLSTransactionSetWindowOverlayContext` | **NO — accepted cross-process** |
| 0x6e | `SLSTransactionSetWindowCreatesOverlayCompositingGroup` | **NO — accepted cross-process** |
| 0x7b | `SLSTransactionSetPluginRenderingIsUnrestrictedForWindow` | YES-ish — flag set cross-process accepted, but does NOT bypass transform check |

### Warp mesh encoding (opcode 0x11)

`SLSTransactionSetWindowWarp(txn, wid, rows, cols, float_array)`:
- `float_array` has `rows * cols` floats (one scalar value per grid point)
- Each float is encoded as packed int (if integer-valued) or 5-byte float (0x88 prefix + 8 bytes)
- This is likely a 1D per-axis displacement field (e.g., genie effect Y-axis deformation)
- NOT a full 2D affine equivalent — arbitrary scale warp not possible in this format

**Direct (non-transaction) `SLSSetWindowWarp` has `CGSWindowGetMappedImpl`** — client-side owned check, same as `SLSSetWindowTransform`.

### SLSTransactionSetWindowTransform3D (opcode 0x10)

- Signature: `(txn, wid, UnsafeRawPointer_to_CATransform3D_16_doubles)`
- CATransform3D = 16 doubles (m11..m44, row-major, 128 bytes total)
- `SLSGetWindowTransform` (2D affine readback) does NOT reflect 3D transform changes
- Cross-process test: blocked — transform not applied

### `SLSCreateLayerContext` correct signature

```swift
// x0 = cid, x1 = first output (Int32*), x2 = second output (Int32*)
// CRASHES if x2 is nil — both output pointers are required
typealias CreateLayerCtxFn = @convention(c) (Int32, UnsafeMutablePointer<Int32>, UnsafeMutablePointer<Int32>) -> Int32
```

Returns status=0 with two distinct IDs. In testing:
- ctxID=522455817 (SLS context ID)
- ctxID2=61299 (CA context ID — small integer, likely slot in WindowServer's context table)

### Overlay compositing group result

Setting `SLSTransactionSetWindowCreatesOverlayCompositingGroup(txn, foreignWID, true)` and
then `SLSTransactionSetWindowOverlayContext(txn, foreignWID, ourCtxID)` — **BOTH ACCEPTED
without rejection** on a foreign window. The commit tokens are positive (not error codes).

However: transform operations on the foreign window AFTER overlay setup remain blocked.
The overlay flag does NOT grant transform rights; it only registers our context as an overlay
layer on top of the window. No visual effect was observed (context may need explicit rendering
to show anything).

**The overlay path is novel and opens a rendering injection angle** (not a transform bypass):
our context can potentially render content on top of any window.

### DYLD injection audit

| App | Location | CS Flags | DYLD injectable? |
| --- | --- | --- | --- |
| TextEdit | /System/Applications/ | platform binary, flags=0x0 | ✗ SIP strips DYLD vars |
| Notes | /System/Applications/ | platform binary, flags=0x0 | ✗ SIP strips DYLD vars |
| Chrome | /Applications/ | `kill,restrict,library-validation,runtime` | ✗ Hardened + restrict + lib-val |
| VS Code | /Applications/ | `runtime`, no lib-val ent | ✗ Hardened, no disable-lib-val |
| Obsidian | /Applications/ | `runtime` + `disable-library-validation` entitlement | **✓ DYLD injection possible** |

**Obsidian DYLD injection is viable** but only useful for transforming Obsidian's own windows.
DYLD injection into the target app (from within which `SLSMainConnectionID()` returns the
process's own connection) would allow transforms on that process's windows — but system apps
and hardened user apps are all protected.

---

## Complete bypass attempt table (Phase 1–3)

| Approach | Result |
| --- | --- |
| `CGSSetWindowTransform` cross-process | Blocked (server-side ownership) |
| `SLSSetWindowTransform` cross-process | Blocked (server-side ownership) |
| `SLSTransactionSetWindowTransform` (0x0f) cross-process | Blocked |
| `SLSTransactionSetWindowTransform3D` (0x10) cross-process | Blocked |
| `SLSTransactionSetWindowWarp` (0x11) cross-process | Blocked |
| `SLSTransactionSetWindowSystemAlpha` (0x0e) cross-process | Blocked |
| `SLSSpaceSetTransform` | Blocked |
| `SLSSetUniversalOwner` without entitlement | status=1002 |
| Ad-hoc signing with private entitlement | AMFI kills (exit 137) |
| Poke conn[0x1d] directly | No server-side effect |
| `SLSSetWindowAlpha` cross-process | Blocked |
| `SLSSetWindowLevel` cross-process | **WORKS** (z-order only) |
| `SLSSetWindowParent` cross-process | **WORKS** (no transform inheritance) |
| Parent-child transform inheritance | No inheritance in compositor |
| `SLSPackagesAddWindowToDraggingSpace` cross-process | Mach msg accepted, no compositor change |
| `SLSPackagesSetWindowDragTransform` cross-process | Drag layer only, not persistent compositor |
| `SLSStructuralRegionSetChildRegionTransform` cross-process | status=0 but accessibility tree only, not rendering |
| `SLSTransactionSetPluginRenderingIsUnrestrictedForWindow` + transform | Unrestricted flag set (accepted), transform still blocked |
| `SLSTransactionSetWindowCreatesOverlayCompositingGroup` cross-process | **WORKS — accepted without ownership check** |
| `SLSTransactionSetWindowOverlayContext` cross-process | **WORKS — accepted without ownership check** |
| DYLD injection into Obsidian | **WORKS** (owns only Obsidian's windows) |
| DYLD injection into TextEdit/Notes/Chrome/VSCode | Blocked |

---

## Conclusion — Approach A

**Approach A (GPU compositor transform AND overlay injection) is definitively not viable with SIP enabled.**

Every known compositor transform entry point in SkyLight has been tested via:
- Direct calls (CGS and SLS variants)
- Transaction-wrapped calls (all opcodes 0x0f, 0x10, 0x11)
- Space-level transform
- Drag-space pipeline (separate layer, not persistent compositor)
- Structural region transform (accessibility tree, not rendering)
- SLSSetUniversalOwner (entitlement-blocked)
- Ad-hoc entitlement signing (AMFI-killed)
- conn[0x1d] memory poke (server-side check ignores it)
- Owner CID passthrough (port identity check defeats it)
- Parent-child transform inheritance (compositor does not propagate)
- Plugin rendering unrestricted flag (does not bypass transform check)
- Overlay compositing group (accepted, but visual injection confirmed BLOCKED — see Phase 3b below)

The wall is precisely:
- **Type:** Server-side ownership check in WindowServer via mach port identity
- **The only bypass:** `com.apple.private.skylight.universal-owner` entitlement (Apple-only),
  OR code injection into Dock.app (requires SIP partially disabled, as yabai documents)

---

## Phase 3b — Overlay rendering injection exhaustive attempt (Probes 08–13)

### Context ID formats tested against SLSTransactionSetWindowOverlayContext

| Context ID source | Value range | Overlay visual result |
| --- | --- | --- |
| `CAContext.localContextWithOptions:` contextId | ~1.75B range (UInt32) | No visual change |
| `CAContext.contextWithCGSConnection:` contextId | ~600M range | No visual change |
| `SLSCreateLayerContext` id2 (slot index) | ~50K range | No visual change |
| `SLSCreateLayerContext` id1 as UInt32 | large neg as unsigned | No visual change |
| `SLSTransactionGetFencingContext` return value | ~87M range | No visual change |
| `CACFContextCreate` → `CARenderContextGetId` | ~2.26B | No visual change |
| CAContext.contextId after CATransaction.flush() | same ~1.75B | No visual change |
| CAContext.contextId after 2s run loop wait | same | No visual change |
| contextId=0 (clear/null) | 0 | Accepted (commits fine, no overlay = expected) |

**Definitive visual test (Probe13 / overlay_visual_test):**  
Our own cyan window with overlay context set to a CAContext containing a full-size bright red layer with "OVERLAY WORKS!!" text → window remains **CYAN** after overlay transaction commit.

### SLSTransactionCommit return values

`SLSTransactionCommit` return value is **NOT** an OSStatus error code. It is a signed 32-bit
transaction sequence counter (increments by 256 per commit). Both "accepted" and "rejected"
overlay transactions return the same kind of positive/negative large integers. Commit status
CANNOT be used to determine overlay acceptance — visual observation is the only ground truth.

### CARenderContext properties (from CARenderContextById)

```
CAContext.contextId → CARenderContextById returns VALID pointer ✓
  procId = our PID
  opts   = 0x0
  level  = -573849600  (anomalous — not a standard window level)
  hostCtxId = 0
  displayId = 0         ← NOT bound to any display
```

The context exists in CARenderServer's table (CARenderContextById finds it), but
the WindowServer compositor refuses to use it as a window overlay. Likely reasons:
- `displayId=0`: not bound to a specific display/screen
- `level` outside valid overlay range
- Requires specific options flags (registry as overlay context vs normal render context)
- May need to originate from a privileged connection (Dock.app / universal-owner)

### SLSSetWindowLayerContext third argument is an ObjC object

`SLSSetWindowLayerContext(cid, wid, thirdArg)` — the `thirdArg` is an ObjC object pointer.
Passing a raw UInt32 (e.g., id2=47651) causes an immediate crash in `objc_msgSend` because
the integer is treated as an object pointer and `retain` is called on address 0xBA23 (not mapped).
The ObjC class is unknown (not exported from SkyLight). This API is not directly usable.

### SLSGetWindowLayerContext

`SLSGetWindowLayerContext(cid, wid) -> UInt32` returns 0 for ALL regular application windows.
Normal app windows do not have a "layer context" set. Layer contexts appear to be used only
by privileged system processes (status bar items, overlays managed by Dock.app).

### CARemoteLayerServer

`CARemoteLayerServer` is the correct cross-process CA layer publishing mechanism. However:
- Requires AppKit (returns nil in CLI processes)
- In AppKit, `+new` and `+serverWithKey:` crashed with `doesNotRecognizeSelector` on this OS version
- Could not instantiate to test its contextId as overlay context

---

## Novel findings (previously undocumented)

1. **`SLSTransactionCommit` returns sequence numbers** — all positive/negative large integers are sequence counters, NOT error codes. Only way to know if overlay worked is visual.

2. **`CARenderContextById(CAContext.contextId)` returns valid pointer** — CAContext IDs map to valid CARenderContext entries in QuartzCore's table. The render context EXISTS but is not accepted for window overlay use by WindowServer.

3. **Overlay compositing group is accepted cross-process** — opcodes 0x6b and 0x6e both accepted without ownership check — but no visual rendering injection results.

4. **`SLSCreateLayerContext` signature** — takes 3 args (cid, ptr1, ptr2); crashes with 2.

5. **Transaction opcode table** — complete encoding of all SkyLight transaction opcodes with their semantic purpose and cross-process behavior.

6. **`SLSSetWindowWarp` direct variant has ownership check** — unlike the transaction variant (no client-side check), the direct warp function has `CGSWindowGetMappedImpl`.

7. **CATransform3D vs CGAffineTransform readback gap** — `SLSTransactionSetWindowTransform3D` changes the 3D transform (16 doubles), which is NOT reflected in `SLSGetWindowTransform` (2D affine readback). Different compositor properties.

8. **Warp mesh is a 1D displacement field** — `rows * cols` scalar floats, NOT 2D coordinate pairs. Likely for single-axis deformation effects (genie). Cannot represent arbitrary 2D scale.

9. **Obsidian DYLD injection confirmed viable** — `com.apple.security.cs.disable-library-validation` entitlement present; launching Obsidian with `DYLD_INSERT_LIBRARIES` loads unsigned dylibs.

10. **`SLSTransactionGetFencingContext`** — returns a valid fencing context ID from an uncommitted transaction. Marking a transaction as "fencing requested" makes it un-committable (assertion failure). The fencing context ID format does not match overlay context requirements.

11. **`SLSSetWindowLayerContext` third arg is ObjC object** — not a UInt32. Passing raw integer crashes in objc_msgSend.

12. **Dock.app does NOT import `SLSTransactionSetWindowOverlayContext`** directly — Mission Control uses a higher-level Bridged API (`SLSBridgedSpaceSetTransformOperation` etc.) or SkyLight-internal code.

---

## Decision: Approach A fully exhausted

After 13 probes and exhaustive investigation, all Approach A paths are confirmed blocked:
- Transform injection (all opcodes): blocked by server-side ownership (mach port identity)
- Overlay rendering injection: accepted mach messages, no visual output produced
- DYLD injection: only useful for the target app's OWN windows

**The path forward is Approach B:**

**B — Virtual displays + ScreenCaptureKit + input forwarding**  
- `CGVirtualDisplay` (SIP-safe, used by BetterDisplay/FreeDisplay)
- Each app genuinely full-screen on its own virtual display → no reflow
- SCK captures each display
- Scaled content displayed in a 2×2 grid window
- Input: cursor warp on entry, `CGEventPostToPid` or CoreHID virtual device for click delivery
- Known risk: SCK may struggle with 4 simultaneous virtual displays (VirtualDisplayKit warning)
