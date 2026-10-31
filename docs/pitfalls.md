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

- Width **900**, height exact **H(N)** with `min == max`. `ExactHeightEQPanel` clamps `setFrame` / `setContentSize`; **no-op when already at the locked size**.
- Middle hugs `max(list, measured side)`; `sideShadowBleed == 0`; `footerClearance == 0`; equal `footerChipInset` (12) above and below the chips. **No footer strip.**
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
