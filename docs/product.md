# Product

What HiFi Companion is, where it is going, what it deliberately is not, what has shipped, and what is next.

## Vision (Mert, 2026-10-28)

- **Origin.** Apple Music does not switch the DAC's SB to match each track. HiFi Companion started as the fix: switch automatically, per track. The original wish was a **bit-perfect** stream; that was not possible with this approach, so the app matches SB instead.
- **The EQ is the core product now.** System-wide PEQ (with the sweep for finding peaks and dips by ear) is the main feature.
- **Apple Music mode is an independent toggle.** Users turn SB matching on or off, with or without the EQ.
- **Pass-through and the "Locked" behavior are development-time, not final.** They exist to make the EQ and matching work during development and will be redesigned from the root, together with Mert. Do not invest in polishing their current design; fix only what blocks development.
- **Auto EQ (future).** Play tones at specific frequencies to correct a headphone's treble automatically. Mert is keeping the details for later — do not design or build it unprompted.
- **Release.** Share the app publicly once development is complete. Windows and Android versions are planned but not certain.
- **Easy to use, simple UI, but feature-rich.** Weigh every design decision against this.
- The agreed next design (output, equalizer switch, signal path, menu panel) is in [redesign-0.3.md](redesign-0.3.md).

## What it is (today)

A macOS menu-bar agent (`LSUIElement`, no Dock icon) for listening on a **hardware DAC**. Today's build does three jobs (the PT / lock mechanics below are the temporary design described above):

1. **Apple Music SB matching.** Switches the macOS output's **SB** (sample rate + bit depth) to the track playing in Apple Music. Matching runs only while Music is the **sole** audible app on the DAC; it locks while anything else plays there and catches up when Music is alone again.
2. **System-wide PEQ (Pass-through).** Optional. A Core Audio **process tap** captures what other apps send to the DAC, runs it through up to 10 parametric bands, and plays it back on the same DAC. Apps keep targeting the DAC; their direct output is muted while tapped.
3. **Sine sweep.** Press-drag on the EQ graph plays a tone at the pointer's frequency. When the tone reveals a peak or dip, **FIX PEAK** / **FIX DIP** adds a correcting band at that frequency.

Write **SB** in caps for sample rate + bit depth everywhere (chat, docs, UI copy).

## What it is not

- Not a music player. No internet radio, discovery, lyrics, or other features most listeners never use.
- Not a virtual audio device. BlackHole / Soundflower / Loopback are never in the path (they are never processed or offered as an output).
- Not bit-perfect when EQ is active. Dry Pass-through is a shared Core Audio hop, not exclusive I/O; active EQ is intentionally colored DSP. The menu says so.

## Platforms

macOS today. Windows and Android versions are planned but not certain. Keep the DSP and EQ model (`PeakingBiquad`, `PEQHeadroom`, `EQBand`, profiles) platform-neutral so the **filter math** can be shared; the audio capture / driver layer is per-platform and is not shared.

## User-facing surfaces

**Menu bar** (title shows SB, `PT …`, `EQ out…`, or `Locked`):

- Apple Music mode note and Pass-through note
- Path status (`Matching only`, `Process tap → DAC (…) · EQ …`), matching status (`Matching: Music alone` / `Locked: …`)
- With PT running: EQ status and `Signal:` meter
- `Track:` and `DAC:` formats, last error in red
- Pass-through toggle, **PEQ…** (opens the EQ window; needs PT), Test tone to DAC (needs PT)
- Output list (System Default + hardware outputs; a picked device becomes the preferred output)
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
- Redesign of Pass-through and the exclusive-Music lock (with Mert).
- Auto EQ (details with Mert).
- Public release prep: Developer ID signing + notarization, app icon, first-run onboarding, updates.
- Windows / Android versions (planned, not certain; only when Mert asks).

## Known gaps (no code change made yet)

- `AppIcon.appiconset` has no images; the app uses the generic icon.
- `project.yml` deployment target is macOS 14.0, while the app needs 14.2 (enforced at runtime by `LSMinimumSystemVersion` and `#available` checks).
- The test target is hosted in the app **and** compiles a subset of app sources directly; it works, but could be simplified to hosted-only.
- Docs have a dark-mode screenshot of the shipped window only; no light-mode shot yet.

## Rejected directions

- The sparse, flat light "Liquid Glass" concept as the EQ visual target.
- BlackHole (or any loopback) as the capture hop.
- Tabs in the EQ window (Tune / Sweep). The graph is always the sweep surface.
