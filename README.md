# macos-window-grid

> **Goal:** Take 4 windows that each fill the screen and display them scaled down
> in a 2×2 grid where you can interact with them as if they were still full-screen.
> Each app keeps rendering at full-screen dimensions and is *optically* shrunk —
> **not resized**, because resizing causes apps to reflow their layouts.

The idea surfaced from a Mission Control glitch: pressing Ctrl+↑ triggered an
unusual state where the scaled-down window thumbnails were fully interactive,
clicks landing at the right spots inside the shrunken content. This repo is the
attempt to build that deliberately.

---

## Does this already exist?

**No.** Confirmed by [waydabber](https://github.com/waydabber) (BetterDisplay
author, the most experienced person in this space) in
[BetterDisplay #612](https://github.com/waydabber/BetterDisplay/issues/612):
*"Not sure there are any similar software that does such a thing."*

| Project | What it does | Gap |
| --- | --- | --- |
| [DeskPad](https://github.com/Stengo/DeskPad) | One virtual display in a window; interactive via click-to-warp. | One display, no grid, no scaling intent; cursor gets lost ([#36](https://github.com/Stengo/DeskPad/issues/36)). |
| [BetterDisplay](https://github.com/waydabber/BetterDisplay) PIP | Unlimited virtual screens in floating windows. Closest thing. | PIP is **view-only**. Interaction open since 2022 ([#612](https://github.com/waydabber/BetterDisplay/issues/612), [#3494](https://github.com/waydabber/BetterDisplay/discussions/3494)). |
| [VirtualDisplayKit](https://github.com/xocialize/VirtualDisplayKit) | MIT SwiftPM wrapper for `CGVirtualDisplay`. | A library. Warns SCK has issues with multiple virtual displays. |
| BetterDisplay + OBS | [View-only side-by-side](https://www.youtube.com/watch?v=oB7EsoycvWM). | Proves demand; not interactive. |
| yabai / Rectangle / AeroSpace | Tiling managers. | They **resize** → apps reflow. Wrong mechanism. |

A GitHub `virtual-display` topic sweep (25 repos) returned only
"use another device as a monitor" and HiDPI tools.

---

## Approach

The Mission Control glitch used macOS's own GPU compositor. WindowServer already
knows how to scale windows as GPU-layer transforms — that is how Exposé, Mission
Control, and Stage Manager work. If we can apply the same transform to arbitrary
windows, rendering stays at full resolution and (critically) the window server's
hit-test may follow the transform, meaning **input requires no extra work**.

The prior literature cites only `CGSSetWindowTransform`. A live export dump of
SkyLight on macOS 26.6.2 (Tahoe, arm64) shows the real surface is much larger:

```
_SLSSetWindowTransform               _SLSTransactionSetWindowTransform
_SLSSetWindowTransforms              _SLSTransactionSetWindowTransform3D
_SLSSetWindowTransformAtPlacement    _SLSSpaceSetTransform
_SLSSetWindowTransformsAtPlacement   _SLSTransactionSetSpaceTransform
_SLSGetWindowTransform               _SLSGetCatenatedWindowTransform
_SLSGetWindowTransformAtPlacement    _SLSSpaceGetTransform
_SLSPackagesSetWindowDragTransform   _SLSPackagesRemoveWindowDragTransform
_SLSStructuralRegionSetChildRegionTransform
_kSLSUserAccessibilityReportWindowTransformKey
_kSLSUserAccessibilityReportSpaceTransformKey
```

`_SLSSpaceSetTransform` is particularly interesting: it transforms an **entire
Space** at once, which is plausibly what Mission Control calls when it zooms out.

### The ownership problem

CGS enforces a window ownership model: an app may only transform windows it
owns. `Dock.app` is the sole "universal owner". `CGSSetUniversalOwner` requires a
private entitlement that only Apple-signed binaries hold. yabai puts
`SLSSetWindowTransform` behind its SIP-disabled OSAX tier for exactly this reason.

**Unknown:** whether passing the target window's owner connection ID (obtainable
via the SIP-safe `SLSGetWindowOwner`) satisfies the check. That is Tier 3 of the
investigation.

**Unknown:** whether the Space-level transform has the same restriction.

---

## Repo structure

Each `Sources/Probe*` target is a standalone executable. They are run in order;
a crash is expected and is itself data. Every result is logged with its
`OSStatus` and visual outcome.

| Target | What it tests |
| --- | --- |
| `Probe01Own` | Tier 1: transform **our own** NSWindow — must succeed (control) |
| `Probe01b` | Tier 1b: hit-test probe on our scaled own window |
| `Probe02` | Tier 2: full symbol sweep against another app's window |
| `Probe03` | Tier 3: owner connection-ID experiment |
| `Probe04` | Tier 4: Space-level transform |

Results are written to [FINDINGS.md](FINDINGS.md) as tiers complete.

---

## Build

```
swift build -c release --target Probe01Own
.build/release/Probe01Own
```

Requires macOS 13+. Grant **Screen Recording** and **Accessibility** to the
built binary before running.

---

## System info

- macOS 26.6.2 (Tahoe), arm64, SIP enabled
- Swift 6.3.3, CommandLineTools only (SwiftPM, no xcodebuild)
- SkyLight symbol inventory obtained via `dyld_info -exports`
