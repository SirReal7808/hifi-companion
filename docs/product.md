# Product

What HiFi Companion is, what it deliberately is not, what has shipped, and what is next.

## What it is

A macOS menu-bar agent (`LSUIElement`, no Dock icon) for listening on a **hardware DAC**. It does three jobs:

1. **Apple Music SB matching.** Pins a hardware DAC and switches that device's **SB** (sample rate + bit depth) to the track playing in Apple Music. Matching runs only while Music is the **sole** audible app on the DAC; it locks while anything else plays there and catches up when Music is alone again.
2. **System-wide PEQ (Pass-through).** Optional. A Core Audio **process tap** captures what other apps send to the DAC, runs it through up to 10 parametric bands, and plays it back on the same DAC. Apps keep targeting the DAC; their direct output is muted while tapped.
3. **Sine sweep.** Press-drag on the EQ graph plays a tone at the pointer's frequency. When the tone reveals a peak or dip, **FIX PEAK** / **FIX DIP** adds a correcting band at that frequency.

Write **SB** in caps for sample rate + bit depth everywhere (chat, docs, UI copy).

## What it is not

- Not a music player. No internet radio, discovery, lyrics, or other features most listeners never use.
- Not a virtual audio device. BlackHole / Soundflower / Loopback are never in the path (they are only excluded from the pin list).
- Not bit-perfect when EQ is active. Dry Pass-through is a shared Core Audio hop, not exclusive I/O; active EQ is intentionally colored DSP. The menu says so.

## Platforms

macOS only until Mert asks for Android. When Android starts, share the **filter math**, not the Mac audio driver.

## User-facing surfaces

**Menu bar** (title shows SB, `PT …`, `EQ out…`, or `Locked`):

- Apple Music mode note and Pass-through note
- Path status (`Matching only`, `Process tap → DAC (…) · EQ …`), matching status (`Matching: Music alone` / `Locked: …`)
- With PT running: EQ status and `Signal:` meter
- `Track:` and `DAC:` formats, last error in red
- Pass-through toggle, **PEQ…** (opens the EQ window; needs PT), Test tone to DAC (needs PT)
- Device pin list (System Default + hardware outputs)
- Appearance (System / Light / Dark), Quit

**EQ window**: graph + sweep, band list, side controls (Output Gain, Bypass EQ, Tone Generator), profiles, undo/redo. Full spec: [eq-window.md](eq-window.md).

## Shipped (v0.2)

- Pin a hardware DAC; Apple Music SB matching with exclusive-Music lock
- Process-tap Pass-through (no BlackHole, no default-output switching, no Microphone prompt)
- PEQ: up to 10 used bands, PK / LS / HS, per-band enable, reorder with ↑/↓
- Response graph with draggable handles, colored wash, sweep needle
- Sweep tone, FIX PEAK (cut) / FIX DIP (boost)
- Output Gain with Auto headroom, Bypass EQ with Gain Match
- Frosted-glass EQ window with side knobs and ALL CAPS side labels
- Compact footer, laptop `visibleFrame` fit, exact window height
- Named profiles (save / overwrite / delete), undo / redo
- System / Light / Dark appearance

Release history and rollback: [releases.md](releases.md).

## Deferred / next

- Bundled first-party virtual device (DriverKit / Audio Server Plug-in) so capture may not need the System Audio Recording prompt. Until then the process tap is the only capture path.
- Band reorder motion polish.
- Android capture + EQ (only when Mert asks).

## Known gaps (no code change made yet)

- `AppIcon.appiconset` has no images; the app uses the generic icon.
- `project.yml` deployment target is macOS 14.0, while the app needs 14.2 (enforced at runtime by `LSMinimumSystemVersion` and `#available` checks).
- The test target is hosted in the app **and** compiles a subset of app sources directly; it works, but could be simplified to hosted-only.
- Docs have a dark-mode screenshot of the shipped window only; no light-mode shot yet.

## Rejected directions

- The sparse, flat light "Liquid Glass" concept as the EQ visual target.
- BlackHole (or any loopback) as the capture hop.
- Tabs in the EQ window (Tune / Sweep). The graph is always the sweep surface.
