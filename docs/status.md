# Status and backlog

Where the project stands and what comes next. Every session reads this first and the `/handoff` skill updates it last, so the next session starts without the chat history. Keep it short and current: finished work moves to [releases.md](releases.md), decisions to the topic docs.

_Last updated: 2026-11-13 (PR #37 open: ⌘Tab, Save Profile name; EQ display-drag jump still open)._

## Now

- **Released:** 0.4.1 (build 36), tag `v0.4.1` → `c31580e`.
- **In development:** 0.4.2 — builds 37 (PR #33) and 38 (PR #35) merged. Build 39 on **PR #37** (`fix/eq-window-display-and-cmd-tab`), installed at `~/Applications/HiFiCompanion.app`.
- **PR #37 state (Mert tested 2026-11-13):** ⌘Tab / Dock while a window is open ✅; Save Profile… prefilled with the active name ✅; EQ display-drag jump ❌ still there. Not merged; finish the jump on the same branch (Next up 1), then ask Mert to merge.
- **Waiting on Mert:** the 0.4.2 release OK (after PR #37). Branches: `main`, `spike/r4b-audibility-probe` (kept), `fix/eq-window-display-and-cmd-tab`.

## Next up

1. **EQ window jumps when dragged to the other display** (branch `fix/eq-window-display-and-cmd-tab`, PR #37). Mert's setup: LG 2560×1440 @1x main at x 0…2560, built-in Retina 1408×881 pt @2x to its right; "Displays have separate Spaces" on.
   - **Cause (log, 2026-11-13):** pressing the title area and dragging never sends `windowWillMove`; when the window crosses to the other display AppKit calls `-[NSWindow _windowMovedToRect:dueToMoveEvent:]` → `_setFrameAfterMove:` → `_setFrame:fromAdjustmentToScreen:anchorIfNeeded:animate:` → our `ExactHeightEQPanel.setFrame(_:display:animate:)`. First crossing: re-anchors to the new screen's right edge (LG → laptop x +1408). Later crossings: restores the frame the window last had on that screen. The drag continues with that offset, so the window is away from the pointer.
   - **Tried, failed:** (a) deferring our sizing during the drag (cause was not ours); (b) ignoring that animate `setFrame` while the button is down: AppKit retries every ~100 ms and its `frame` stays stale, so the window shifts on drop; (c) removing `.canJoinAllSpaces`: same re-anchor.
   - **Next ideas:** make the drag a real AppKit user drag — a small `NSView` behind the toolbar row whose `mouseDown` calls `window.performDrag(with:)` (then `windowWillMove` fires and AppKit should not re-anchor); check `mouseDownCanMoveWindow` / `isMovableByWindowBackground`; a plain test `NSWindow` (same style mask, no SwiftUI) to see if AppKit re-anchors it too. Diagnostic: `EQDIAG animated setFrame during drag` notice log (`/usr/bin/log show --predicate 'subsystem == "HiFiCompanion" && category == "PEQPanel"'`; remove it before merge).
   - **Done when:** dragging LG ↔ laptop several times both ways keeps the window under the pointer, during and after the drag (Mert's test). Run `eq-window-reviewer`.
2. **Release 0.4.2** (builds 37 + 38 + 39) with `/release` once Mert says so. Mert used build 37 daily 2026-11-01…12; `audio-events.log` (10–12 Nov) shows no stream breaks or tap errors.

## Backlog (not scheduled)

Small, Mert has not asked for them; propose before starting.

- **Null test at other rates.** Bit-exactness was measured at 44.1 kHz only (DX5 II). Run `scripts/null-test.sh` with the DAC at 96 kHz (and 48 kHz) when nobody is listening. Measurement only.
- **Format lines from other apps.** `LogStreamReader` takes `AudioQueue` lines from any process in `com.apple.coreaudio`; a bogus 48 kHz line (likely another app) was held as Music's next track on 2026-10-31 21:20. Harmless since build 36 (AppleScript decides at the track change), but filtering `AudioQueue` lines to Music would remove the noise. Needs `audio-path-reviewer`.
- **Code-review leftovers (2026-10-28, low):** `PEQView.swift` is 2,000 lines (split by component, no visual change); `isPassThroughFailure` classifies errors by text; logging mixes `print` and `os.Logger`; `project.yml` deployment target 14.0 vs the 14.2 the app needs; test target both hosted and compiling app sources.
- **Docs media:** no light-mode EQ screenshot.

## Later (Mert decides when)

- AutoEQ `ParametricEQ.txt` import / export; Auto EQ (Mert holds the details).
- Public release prep: Developer ID signing + notarization, app icon, updates.
- Windows / Android (maybe never).
- Bundled virtual device so capture needs no System Audio Recording prompt.

## Decided — do not re-propose

- Pausing / resuming Music around a rate switch: no. The ~1 s gap at the start of a track with a new rate is normal (2026-11-01).
- Audible-only exclusive lock: dropped; the ~10 s browser delay is accepted (README → Known behavior).
- Wiring the Apps exclusion list into the tap, level meter while the equalizer is off, a level bar in the panel, ⌘1–9 profile shortcuts: declined (2026-10-31).
- Global EQ hotkey, device "cards", tabs in the EQ window, BlackHole or any loopback hop.
