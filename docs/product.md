# Product

What HiFi Companion is, where it is going, what it deliberately is not, what has shipped, and what is next.

## Vision (Mert, 2026-10-28)

- **Origin.** Apple Music does not switch the DAC's SB to match each track. HiFi Companion started as the fix: switch automatically, per track. The original wish was a **bit-perfect** stream; that was not possible with this approach, so the app matches SB instead.
- **The EQ is the core product now.** System-wide PEQ (with the sweep for finding peaks and dips by ear) is the main feature.
- **Apple Music mode is an independent toggle.** Users turn SB matching on or off, with or without the EQ.
- **Pass-through and the "Locked" behavior were development-time designs.** They were redesigned with Mert in 0.3.0 ([redesign-0.3.md](redesign-0.3.md)): the Parametric Equalizer switch, output follow / preferred device, and Apple Music Mode with a gray **Paused** state.
- **Auto EQ (future).** Play tones at specific frequencies to correct a headphone's treble automatically. Mert is keeping the details for later — do not design or build it unprompted.
- **Release.** Share the app publicly once development is complete. Windows and Android versions are planned but not certain.
- **Easy to use, simple UI, but feature-rich.** Weigh every design decision against this.

## What it is (today)

A macOS menu-bar agent (`LSUIElement`; Dock icon and ⌘Tab entry only while one of its windows is open) for listening on a **hardware DAC** (or any hardware output). Three jobs:

1. **System-wide PEQ (Parametric Equalizer switch).** A Core Audio **process tap** captures what other apps send to the macOS output, runs it through up to 10 parametric bands, and plays it on the same device. Apps keep targeting the device; their direct output is muted while tapped. Each output device keeps its own curve. With the equalizer flat, the path is bit-exact on USB outputs (null test, 0.4.1).
2. **Apple Music Mode (SB matching).** Switches the output's **SB** (sample rate + bit depth) to the track playing in Apple Music, at the track change. It works only while Music is the **sole** audible app on the device; it pauses while anything else plays there and catches up when Music is alone again.
3. **Sine sweep.** Press-drag on the EQ graph plays a tone at the pointer's frequency. When the tone reveals a peak or dip, **FIX PEAK** / **FIX DIP** adds a correcting band at that frequency.

Write **SB** in caps for sample rate + bit depth in chat and docs; the UI says "Sample Rate / Bit Depth".

## What it is not

- Not a music player. No internet radio, discovery, lyrics, or other features most listeners never use.
- Not a virtual audio device. BlackHole / Soundflower / Loopback are never in the path (they are never processed or offered as an output).
- Not bit-perfect when the EQ is active: active EQ is intentionally colored DSP, and the tap is a shared Core Audio path, not exclusive I/O. The UI never says "bit-perfect".

## Platforms

macOS today. Windows and Android versions are planned but not certain. Keep the DSP and EQ model (`PeakingBiquad`, `PEQHeadroom`, `EQBand`, profiles) platform-neutral so the **filter math** can be shared; the audio capture / driver layer is per-platform and is not shared.

## User-facing surfaces

**Menu bar title**: "HiFi Companion" (placeholder until the logo exists), or any of Device / SB / Profile picked in Settings → General, joined with " · ".

**Menu panel** (since R5):

- Output device name and SB
- Signal path line with a colored dot (Direct green, Parametric Equalizer blue, Resampled / Mixed / Bluetooth (lossy) yellow, Idle gray); hover shows the full chain
- **Parametric Equalizer** switch (subtitle when unavailable, e.g. "Unavailable — Qobuz exclusive"), **Profile** submenu (switches without opening the window), **Open Equalizer… ⌘E**
- **Apple Music Mode** switch (hover: explanation)
- **Output** submenu (System Default + hardware outputs; a picked device becomes the preferred output), **Settings… ⌘,**, **Quit ⌘Q**

**Settings window**: General (launch at login, menu bar title items, Appearance), Output (preferred device, curves by device with Forget), Apps (equalizer exclusion list — saved, not yet honored by the tap), Diagnostics (signal path, equalizer status, input level meter, bands / peak boost / output gain / headroom, output device connection / formats / buffer / latency, Stream Health (dropouts, slow cycles, Show audio log), Apple Music Mode state and track format, last error, version). The menu test tone is gone: it is silent while the tap aggregate is cold (nothing playing), see audio-path.md.

**First run**: an explainer before the System Audio Recording prompt (first launch, and before the first equalizer enable until the user chooses "Turn On Equalizer").

**EQ window**: graph + sweep, band list, side glass (OUTPUT gain, Auto Gain, Bypass EQ, Gain Match, SWEEP level, FIX PEAK / FIX DIP), profiles, undo / redo. Full spec: [eq-window.md](eq-window.md).

## Shipped

Per-release details: [releases.md](releases.md). In short:

- **0.2** — PEQ (10 bands, PK / LS / HS), graph with handles and colored wash, sweep with FIX PEAK / DIP, Output Gain with Auto headroom, Bypass EQ with Gain Match, profiles, undo / redo, compact EQ window.
- **0.3.0** — follow the macOS output with an optional preferred device, Parametric Equalizer switch, per-device curves, Apple Music Mode switch, signal path, menu panel, Settings, launch at login, first-run explainer.
- **0.4.0** — EQ window in native Liquid Glass.
- **0.4.1** — bit-exact flat path (drift compensation off on hardware outputs), dropout log, null test, rate switches only at track changes.
- **0.4.2** — menu panel fixes (closes on Open Equalizer / Settings, follows the macOS appearance); EQ window in ⌘Tab / Dock, Save Profile name, display drag.

## Next

What is in flight, the next tasks, the backlog and declined ideas: [status.md](status.md). Longer-term: AutoEQ import / Auto EQ, public release prep (signing, notarization, icon, updates), a bundled virtual device so capture needs no prompt, other platforms — all when Mert asks.

## Known gaps

- `AppIcon.appiconset` has no images; the app uses the generic icon.
- `project.yml` deployment target is macOS 14.0, while the app needs 14.2 (enforced at runtime by `LSMinimumSystemVersion` and `#available` checks).
- The test target is hosted in the app **and** compiles a subset of app sources directly; it works, but could be simplified to hosted-only.

## Rejected directions

- The sparse, flat light "Liquid Glass" concept (2026-10). The native Liquid Glass shipped in 0.4.0 is a different direction.
- BlackHole (or any loopback) as the capture hop.
- Tabs in the EQ window (Tune / Sweep). The graph is always the sweep surface.
- More in [status.md → Decided](status.md#decided--do-not-re-propose).
