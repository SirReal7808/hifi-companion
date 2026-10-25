# HiFi Companion

macOS menu-bar app that matches your pinned external DAC’s sample rate and bit depth (SB) to the track currently playing in Apple Music, with an optional **pass-through** hop through a virtual output into that DAC.

Phase 1 focus: Music SB matching, exclusive-Music lock, and EQ-off pass-through. No PEQ UI or sweep yet.

**Requirements:** macOS 14+, Xcode 15+, Apple Music. Not sandboxed and not intended for the Mac App Store (`log stream` needs unsandboxed access).

## Virtual device choice (pass-through)

Pass-through needs a system **virtual output** that apps can play into, plus a capture side we can read.

For this slice we use **[BlackHole 2ch](https://github.com/ExistentialAudio/BlackHole)** (MIT, Existential Audio) instead of shipping a first-party Audio Server Plug-in / DriverKit extension. A full in-repo ASP is the longer-term path; BlackHole is the maintainable way to prove the hop on modern macOS now.

### Install BlackHole 2ch

```bash
brew install --cask blackhole-2ch
```

Or download the installer from [existential.audio/blackhole](https://existential.audio/blackhole/). A reboot (or restarting Core Audio) may be required before **BlackHole 2ch** appears in Audio MIDI Setup.

HiFi Companion looks for device UID `BlackHole2ch_UID` / name **BlackHole 2ch**.

### Feedback-loop warning

Never set the pinned DAC to BlackHole, and never route the bridge output back into BlackHole. Pass-through is always **BlackHole (apps) → HiFi Companion → pinned hardware DAC**. Enabling that path incorrectly can cause howling / a feedback loop.

## Apple Music mode

Apple Music mode switches SB on the Music-facing device **only while Music is the sole app sending audio there**.

- Music alone → match as usual (and, with pass-through on, keep BlackHole and the DAC on the same SB).
- Any other audible client on that path (for example YouTube while the system default is BlackHole) → **lock**: keep the current format; ignore new applies until unlocked. Menu bar shows **Locked**.
- When others stop and Music is alone → **unlock** and catch up.
- Silent apps do not lock. Short system chirps are softened with grace + an ignore list.

With pass-through **on**, lock is evaluated on the **virtual** device (where apps render). With pass-through **off**, lock is evaluated on the pinned / default hardware DAC.

## Pass-through

Menu toggle **Pass-through**:

1. Remembers the previous default output.
2. Sets **BlackHole 2ch** as the system default output (apps render there).
3. Captures from BlackHole and writes **unchanged** PCM to the **pinned** DAC (AVAudioEngine hop, no EQ).
4. On disable or quit: stops the bridge and restores the previous default output.

Status examples: `Matching only` vs `Virtual → DAC (BlackHole 2ch → DX5 II)`. While running, the menu bar may show `PT 96 kHz / 24-bit`.

macOS will ask for **microphone** access so the app can capture from BlackHole’s input side. Nothing is recorded to disk.

### Honest limits

- EQ-off pass-through is a **transparent shared Core Audio hop**, not bit-perfect exclusive I/O.
- Sample-rate changes make the DAC reclock. At track starts that coincide with a rate change, brief dropouts or silence are normal.
- Some DACs click or pop on reclock; that is hardware behavior.
- Other apps on the same path would glitch if a switch ran while they play; the exclusive-Music lock skips switches while they are audible.

## Build in Xcode

1. Open `HiFiCompanion.xcodeproj`.
2. Select the **HiFi Companion** scheme and **My Mac**.
3. Signing: choose your Team (or Sign to Run Locally).
4. Product → Build (⌘B), then Product → Run (⌘R).

```bash
xcodegen generate   # only if project.yml changed
xcodebuild -scheme "HiFi Companion" -configuration Release -derivedDataPath build
open "build/Build/Products/Release/HiFiCompanion.app"
```

## Run

- Menu-bar agent (`LSUIElement`): no Dock icon.
- Pin your real DAC (BlackHole is hidden from the pin list).
- Optionally enable **Pass-through** after BlackHole is installed.
- Quit from the menu (restores the previous default output if pass-through was on).

## Test checklist

1. Music alone, matching only: 44.1 ↔ 96 follows in Audio MIDI Setup.
2. Enable pass-through: system default becomes BlackHole; audio is heard on the pinned DAC; no howling.
3. Disable pass-through or quit: previous default output is restored.
4. Pass-through + Music + YouTube: matching locks; stop YouTube → unlock and catch up.

## Phase scope

**Included:** menu-bar status item, DAC pin, Music SB detection, exclusive-Music lock, BlackHole pass-through hop.

**Out of scope (next slices):** PEQ bands, gain slider, sine sweep, Fixed mode UI, first-party ASP.
