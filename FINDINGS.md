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

### What `SLSSetWindowTransformAtPlacement` actually does

Disassembly of `SLSSetWindowTransform` at offset `0x33B38C` reveals it is a **thin wrapper**:

```
// Copy the CGAffineTransform to stack
ldp q0, q1, [x2]      // x2 = pointer to input transform
stp q0, q1, [sp]
ldr q0, [x2, #0x20]
str q0, [sp, #0x20]   // 48 bytes copied

// Call the real function with placement=0, 0
mov x4, sp            // x4 = stack copy pointer
mov w2, #0
mov w3, #0
bl  SLSSetWindowTransformAtPlacement
```

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

**There is NO client-side ownership check.** The function builds and sends a mach message
to WindowServer unconditionally. WindowServer receives it and enforces ownership server-side
by checking whether the sending mach port corresponds to a connection with `universal-owner`
permission or ownership of the target window.

### Dock.app's entitlement

```
com.apple.private.skylight.universal-owner = true
```

This entitlement, set at connection time, grants WindowServer permission to apply transform
requests from that connection to **any** window. It is an Apple-private entitlement only
available to Apple-signed binaries and therefore cannot be claimed by third-party processes
on a SIP-enabled system.

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

---

## Conclusion

**Approach A (GPU compositor transform) is not viable with SIP enabled.**

The wall is:
- **Type:** Server-side ownership check in WindowServer (not in SkyLight)
- **Enforcement mechanism:** Mach port identity — WindowServer checks the *sending port*
- **The only bypass:** `com.apple.private.skylight.universal-owner` entitlement (Apple-only),
  OR code injection into Dock.app (requires SIP partially disabled, as yabai documents)

**Also found:** Per-window CGS transforms are purely visual — input routing is unchanged.
The Mission Control interactive thumbnail behaviour uses a different mechanism (likely
`SLSSpaceSetTransform` which probably does affect hit-testing at the Space level).

---

## Next: decide fallback

Per the plan, the fallback choice is deferred until Phase 1 evidence is in.
Options:

1. **B — Virtual displays + ScreenCaptureKit + cursor warp / CoreHID input**  
   `CGVirtualDisplay` (SIP-safe, used by BetterDisplay/FreeDisplay). Each app is genuinely
   full-screen on its own display → no reflow. Core challenge: cursor model.
   Risk: VirtualDisplayKit warns SCK struggles with multiple virtual displays.

2. **C — Window capture + `CGEventPostToPid` for input**  
   No virtual displays; simpler setup. Risk: occlusion throttling, per-app input rejection.

3. **SIP partial disable** — gives Approach A fully. Requires user choice.
