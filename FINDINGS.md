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

## Conclusion

**Approach A (GPU compositor transform) is definitively not viable with SIP enabled.**

Every known compositor transform entry point in SkyLight has been tested via:
- Direct calls (CGS and SLS variants)
- Transaction-wrapped calls
- Space-level transform
- Drag-space pipeline (separate layer, not persistent compositor)
- Structural region transform (accessibility tree, not rendering)
- SLSSetUniversalOwner (entitlement-blocked)
- Ad-hoc entitlement signing (AMFI-killed)
- conn[0x1d] memory poke (server-side check ignores it)
- Owner CID passthrough (port identity check defeats it)
- Parent-child transform inheritance (compositor does not propagate)

The wall is precisely:
- **Type:** Server-side ownership check in WindowServer via mach port identity
- **The only bypass:** `com.apple.private.skylight.universal-owner` entitlement (Apple-only),
  OR code injection into Dock.app (requires SIP partially disabled, as yabai documents)

---

## Next: decide fallback approach

1. **B — Virtual displays + ScreenCaptureKit + cursor warp / CoreHID input**  
   `CGVirtualDisplay` (SIP-safe, used by BetterDisplay/FreeDisplay). Each app is genuinely
   full-screen on its own display → no reflow. Core challenge: cursor model.
   Risk: VirtualDisplayKit warns SCK struggles with multiple virtual displays.

2. **C — Window capture + `CGEventPostToPid` for input**  
   No virtual displays; simpler setup. Risk: occlusion throttling, per-app input rejection.

3. **SIP partial disable** — gives Approach A fully. Requires user choice.
