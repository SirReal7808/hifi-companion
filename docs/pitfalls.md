# Pitfalls (keep these fixes)

Each item is a regression we already paid for. Symptom → cause → **the fix we must keep**. Details of old SHAs are omitted on purpose.

## Window height, clip, and footer

**Symptom:** EQ opens taller than the laptop (void under Add Band / Reset); Peak/Dip sit under a dark strip; side glass bottom corners or shadow are cut; Add Band / Reset not clickable; window grows when dragging the bottom edge; F: labels clip.

**Cause (several layers, all real):**

- `NSHostingView` + `fullSizeContentView` re-expanded by ~32 pt after `setContentSize`.
- Middle `GeometryReader` / `maxHeight: .infinity` / `layoutPriority(1)` opened a void and stole hits from the chips.
- `contentLayoutRect` was 0 before layout → `minSize.height` ballooned past `max` → AppKit collapsed or closed the panel.
- `setContentSize` grows upward; Add Band appeared to “shift the window up.”
- A **footer layer** or `.clipped()` on the middle column masked the side glass shadow.
- In-flow status banners (rebuild / “enable PT”) inserted a row, grew past H(N), and shoved Peak/Dip into the footer.
- PreferenceKey side-height chatter fought ExactHeight (see CPU below).
- Oversized `sideControlsHeight` constants left a void under a short band list.
- Stale `~/Applications/HiFiCompanion.app` — probes on DerivedData were correct; Spotlight launched yesterday’s binary.

**Fix we keep:**

- Width **790** (900 before the glass styling), height exact **H(N)** with `min == max`. `ExactHeightEQPanel` clamps `setFrame` / `setContentSize`; **no-op when already at the locked size**.
- Middle hugs `max(list, measured side)`; `sideShadowBleed == 0`; `footerClearance == 0`; equal `footerChipInset` (12) above and below the chips. **No footer strip.** The chips are framed to exactly `footerHeight` (30): with intrinsic ~28 pt chips under a 34 pt budget, H(N) was 6 pt taller than the content and the bare window showed as a dark strip under the chips (fixed 2026-10-31).
- **Never** `.clipped()` / `.compositingGroup()` / fixed-height shell on the middle — the glass shadow paints into the chip inset. [media/eq-v0.2-dark.jpg](media/eq-v0.2-dark.jpg), [media/eq-v0.2-footer-corner.jpg](media/eq-v0.2-footer-corner.jpg).
- On short screens: clamp to `visibleFrame − 16`; shrink graph (min 140) first, then middle; never clip the side glass to make it fit.
- Re-pin top-left after size changes (`origin.y = oldMaxY - newHeight`).
- No in-flow banners. Clipping warning is a graph overlay.
- `testCompactFooterInvariant`; full rule in [eq-window.md](eq-window.md#compact-footer--locked-2026-10-27).
- After every pull: ditto to `~/Applications/HiFiCompanion.app` and read `stamp=` / `ver=` / `exe=`.

## CPU from PreferenceKeys (and poll republish)

**Symptom:** Activity Monitor ~90–120% with the EQ open and idle; Bypass EQ jank; WindowServer busy.

**Cause:**

1. Side-column `GeometryReader` / `PreferenceKey` → `measuredSideHeight` → `applySizing` → `setFrame` → layout again. Sub-point chatter kept materials invalidating.
2. Device poll (~0.4 s) assigned `@Published` `devices` / `signalMeterText` / path strings even when unchanged → full `PEQView` rebuild of Canvas + `.regularMaterial` ~2.5×/s.
3. ExactHeight calling `super.setFrame` on every hostile +32 pt hosting request re-entered layout.

**Fix we keep:** quantize side-height probes; early-out `applySizing` when already at H(N); equality-guard poll publishes; `Transaction(animation: nil)` on Bypass + graph; no PreferenceKey layout loop. Idle CPU with EQ open should be ~1%, not 100%.

## PT silence vs sweep engine contention

**Symptom:** Pass-through on, Music already playing, DAC silent (or silent until Music is started). Sweep may still work. Signal meter may show silence.

**Cause:**

- A dedicated `AVAudioEngine` → DAC for Sweep was started at PT enable (or left running after a gesture). Our pid is excluded from the tap; that engine is a second client on the same DAC and fights the aggregate. Music through the tap goes mute while `mutedWhenTapped` has already silenced the app’s direct output.
- `AudioDeviceStart(aggregate, nil)` instead of the IOProc id — aggregate never really ran.
- Render path could output silence if tap input was empty/optional.
- Sweep mixed **only** in the aggregate IOProc is silent when no tapped app is waking IO (fresh PT, no Music yet). That part is expected; the wake engine exists for that case.

**Fix we keep:**

- Mix Sweep on the aggregate when IO is warm.
- Start `dacWakeEngine` only in `beginSweepTone` when aggregate is **cold**.
- `endSweepTone` / `hardMute` **stop and detach** it. Never idle-run it.
- `AudioDeviceStart(aggregate, procID)`; copy tap → output only with real tap input.
- `--smoke-sweep`: engine idle → on during gesture → off after.

## Launch crash from throwaway window

**Symptom:** Immediate `EXC_BAD_ACCESS` / `SIGSEGV` in `objc_release` on launch or `--show-eq` (stamp `window-chrome-v6` era).

**Cause:** `standardCloseInsets()` constructed a temporary `NSWindow`, then `close()`’d it. Default `isReleasedWhenClosed == true` → AppKit released + ARC released → over-release on the next main-queue pool pop.

**Fix we keep:** **no probe window.** Constant close insets `(7, 6)`; nudge only if packed into the corner. Nil / non-finite frame guards. Do not `setFrameSize(.zero)` on mini/zoom (that shifted close). Do not hide buttons in a way that collapses layout.

## Signed zero dB

**Symptom:** Output Gain / Tone Gain / band G / menu strings showed `+0.0 dB` or `-0.0 dB`.

**Cause:** `String(format: "%+.1f", value)` keeps a sign for IEEE negative zero and for values that round to zero.

**Fix we keep:** `EQFormat.gainDB` rounds, then prints exact zero as `0.0` / `0` with **no sign**. Non-zero keeps an explicit sign. Tests in `EQFormatTests`. Use this helper for every dB readout.

## Zoom button

**Symptom:** Green zoom (or live resize) stretched the panel; height no longer matched H(N); void under the footer came back.

**Cause:** `.resizable` / zoom / `windowShouldZoom` allowed AppKit to ignore ExactHeight. Combined with flexible SwiftUI stacks, any extra height became empty glass.

**Fix we keep:** style mask **titled + closable + fullSizeContentView only**. Hide/disable/alpha-zero the zoom button; `windowShouldZoom` → false; `fullScreenNone`. Vertical drag is a no-op. Height changes only when band count or measured side height changes (or the screen cap).

## Tap drift compensation resampled the audio

**Symptom:** none audible; the null test found that with the equalizer flat, no sample reached the DAC unchanged.

**Cause:** `kAudioSubTapDriftCompensationKey: true` on the tap sub-device makes macOS run the tap through a resampler, even though the tap carries audio bound for the same DAC (same clock, no drift).

**Fix we keep:** drift compensation **off** for hardware-clocked outputs (`TapClockPolicy`; on for Bluetooth / AirPlay / aggregate / virtual / unknown, which may not share the tap's clock); `scripts/null-test.sh` proves the flat path bit-exact. Watch long listening sessions for clicks — if they ever appear, revisit this first.

## Next-track preload reclocked the DAC mid-track

**Symptom:** a ~1 s gap about 20 s before a track ends when the next track has another sample rate; or a hi-res track playing at the old rate until paused.

**Cause:** Music logs the next track's format when it preloads it for gapless playback, and sometimes logs nothing at the real start. Detections were taken as "the playing track".

**Fix we keep:** rate changes are checked against AppleScript's playing-track rate and held until the track change; the track change applies the playing track's rate (`NextTrackGuard`). See [audio-path.md](audio-path.md#sb-matching-apple-music-mode).

## Streaming bandwidth dip reclocked the DAC mid-track

**Symptom:** a 96 kHz track drops to 48 kHz part-way through and comes back by itself, with a short gap at each switch (2026-11-14 13:18, build 45).

**Cause:** Apple Music's adaptive HLS switched the same track to a lower variant (48 kHz AAC) and logged a new AudioQueue; AppleScript did not hold it back.

**Fix we keep:** once the playing track's rate is matched, other rates are held until the next track change (`NextTrackGuard.decide(matchedTrackRate:)`). Never reclock for a variant switch of the playing track.

## Mid-track tap rebuild on an unchanged format

**Symptom:** a single ~0.2 s hiccup in the middle of a track, rarely.

**Cause:** SB matching compared the *track* format with the last applied one. Detection sources disagree on bit depth (ALAC 16-bit vs AudioQueue 24-bit), so a late second report looked like a new format, and the tap was stopped, the same DAC format rewritten, and the tap rebuilt — mid-track. The dropout log showed it (`Tap stopped` … `Tap rebuild (sb-match)` with no `Track changed` and the DAC at the same 44.1 / 24).

**Fix we keep:** compare what the DAC *would* be set to (`plannedFormat`) with what it is; if equal and the tap is already there, accept without touching audio (`isNoOpSwitch`).

## EQ window jumped when dragged to the other display

**Symptom:** dragging the EQ window from one display to the other (LG @1x ↔ built-in Retina @2x, "Displays have separate Spaces" on) threw it away from the pointer — first to the new screen's edge, later to the frame it last had on that screen — and the drag went on with that offset.

**Cause:** the system title-bar drag is moved by the WindowServer; `windowWillMove` is never sent. When the window crossed displays, AppKit's `_windowMovedToRect:dueToMoveEvent:` → `_setFrameAfterMove:` → `_setFrame:fromAdjustmentToScreen:anchorIfNeeded:animate:` re-anchored it. Ignoring that `setFrame` did not help: AppKit's `frame` was stale against the server-moved window, so it retried and the window shifted on drop. Removing `.canJoinAllSpaces` did not help either.

**Fix we keep:** `isMovable = false`; `EQWindowDragView` behind the toolbar moves the window itself from `NSEvent.mouseLocation` deltas, so AppKit's `frame` is always the real one, and `ExactHeightEQPanel` drops every other frame change while that drag runs. Do not bring back the system title-bar drag or `isMovableByWindowBackground`.

## Related landmines (short)

| Symptom | Keep |
|---|---|
| Add Band / Reset clipped after reopening the window | Create a **fresh** `NSHostingController` on every `show()`; a reused one never re-fires the side-glass PreferenceKey after `measuredSideHeight` is reset, so H(N) used the fallback. Keep `sideControlsHeight` ≥ the real glass (400 vs 399). Check with `--eq-reopen`. |
| Band delete / reopen crash | Do not call `applySizing` synchronously from `windowDidResize` (re-entrancy). When shrinking, do not lower `maxSize` before the frame. Disable list/window animations on add/remove. |
| Reset / dialogs not clickable | Use `.alert` (AppKit sheet), not `.confirmationDialog` under a full-slot `contentShape`. Disable middle hit-testing while the alert is up. |
| F: cropped | Filter type is a **Menu**, not a wide Picker; F/G/Q `fixedSize` + layoutPriority. |
| Checkbox chrome drifts | Pure-SwiftUI `GlassCheckbox`, not AppKit `.toggleStyle(.checkbox)`. |
| EQ UI disabled banner on SB change | Keep controls live across `isPassThroughRebuilding`; do not insert a caption row. |
| IOProc never fires | Create the IOProc with a **nil** queue; do not bind it to the control `DispatchQueue`. |
| Heap in realtime | `PeakingBiquad.processInterleaved` — no `AVAudioPCMBuffer` alloc in the IOProc. |
| Mini/zoom `setFrameSize(.zero)` | Shifts the close button; hide via alpha/enabled, not zero frames. |
