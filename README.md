# HiFi Companion

macOS menu-bar app that matches your pinned external DAC’s sample rate and bit depth (SB) to the track currently playing in Apple Music, with an optional **pass-through** hop through a virtual output into that DAC.

Phase 1 focus: Music SB matching, exclusive-Music lock, BlackHole pass-through, and a **one-band test EQ** (gain slider). Full multi-band PEQ UI and sweep come later.

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

**How it should sound:** With Pass-through on and a hardware DAC pinned (e.g. DX5 II), Apple Music (and other apps) play into **BlackHole 2ch**, and HiFi Companion immediately copies that PCM to the pinned DAC. You should hear Music on the DAC—not from the Mac speakers—and the menu status should read `Virtual → DAC (BlackHole 2ch → …)`. At **0 dB / Bypass** the hop is dry; boosting Test EQ at 1 kHz should color the same path. Turning Pass-through off stops the bridge and restores the previous default output right away.

Menu toggle **Pass-through**:

1. Requires a **pinned hardware DAC** (refuses if nothing is pinned, or if the pin is BlackHole / a bridge-only aggregate).
2. Remembers the previous default output.
3. Sets **BlackHole 2ch** as the system default output (apps render there).
4. Captures from BlackHole and writes PCM to the **pinned** DAC (AVAudioEngine: input → EQ → DAC). With test EQ at **0 dB / Bypass**, the hop stays dry.
5. On disable or quit: stops the bridge and restores the previous default output. If the app crashed while Pass-through was on, the next launch restores the previous default so you are not left on silent BlackHole.

Status examples: `Matching only` vs `Virtual → DAC (BlackHole 2ch → DX5 II) · EQ bypass`. Failures show as `Pass-through error: …` in the status line (and the red error row). While EQ is boosted, the menu bar may show `EQ +6 dB`. **Test EQ…** stays disabled until the bridge is actually running.

### Silent DAC troubleshooting

If the system default is BlackHole but the DAC is silent: (1) confirm **DX5 II** (or your DAC) is pinned—not BlackHole; (2) allow **Microphone / Input** for HiFi Companion in System Settings → Privacy & Security → Microphone (needed to capture BlackHole, not the laptop mic); (3) check the menu for a `Pass-through error:` line — Core Audio `'nope'` / illegal-operation means the device was busy reconfiguring (fixed by starting the bridge *before* switching default); (4) disable Pass-through (restores default) and enable once; (5) confirm BlackHole 2ch appears in Audio MIDI Setup. A failed enable must not leave you on silent BlackHole.

### Input / “Microphone” permission (v1 BlackHole artifact)

macOS may show an **Input / Microphone** privacy prompt when pass-through starts. That is required to capture **system audio from BlackHole’s virtual device**, not the laptop microphone. Nothing is recorded to disk. Pass-through always **re-queries** permission on toggle and still **tries to open** BlackHole even if one API reports denied—System Settings can show Allowed while `AVAudioApplication` lags after an ad-hoc rebuild. If open fails, the menu shows the **real** Core Audio / engine error (not a blanket deny). Denial leaves the previous default output in place (not silent BlackHole).

**Stable binary / TCC:** Prefer one install path so Settings ↔ the running app stay matched:

```bash
mkdir -p ~/Applications
rm -rf ~/Applications/HiFiCompanion.app
ditto "build/Build/Products/Release/HiFiCompanion.app" ~/Applications/HiFiCompanion.app
open ~/Applications/HiFiCompanion.app
```

After a rebuild, if Settings already shows Microphone **On** but Pass-through still cannot capture: turn the HiFi Companion row **Off** then **On** once, or quit the app and run `tccutil reset Microphone com.hificompanion.app` then enable Pass-through again (macOS will re-prompt). Do not reset other apps’ Microphone entries. **The final product goal is a bundled virtual device that does not need this prompt.**

### Test EQ (one peaking band)

Only while **Pass-through** is on (matching-only stays dry):

1. Menu → **Test EQ…** opens a small panel.
2. Fixed band: **1 kHz peaking**, Q ≈ **1.41** (clear on headphones without a full PEQ UI).
3. Drag **Gain** (−12…+12 dB). At **0 dB** / **Bypass**, EQ is off and the path is dry. When gain ≠ 0, the menu shows EQ **active** — the path is **not bit-perfect**.

### Honest limits

- Dry pass-through is a **transparent shared Core Audio hop**, not exclusive bit-perfect I/O. Active EQ is intentionally colored DSP.
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
mkdir -p ~/Applications && rm -rf ~/Applications/HiFiCompanion.app
ditto "build/Build/Products/Release/HiFiCompanion.app" ~/Applications/HiFiCompanion.app
open ~/Applications/HiFiCompanion.app
```

Keep launching the **same** `~/Applications/HiFiCompanion.app` (not a one-off DerivedData/`build/` path) so the Microphone TCC row matches the binary you run.

## Run

- Menu-bar agent (`LSUIElement`): no Dock icon.
- Pin your real DAC (BlackHole is hidden from the pin list).
- Optionally enable **Pass-through** after BlackHole is installed.
- Quit from the menu (restores the previous default output if pass-through was on).

## Test checklist

1. Music alone, matching only: 44.1 ↔ 96 follows in Audio MIDI Setup.
2. Enable pass-through: system default becomes BlackHole; audio is heard on the pinned DAC; no howling; EQ bypassed.
3. **Test EQ…** → boost gain (e.g. +6 dB) → hear the 1 kHz band; set 0 dB / Bypass → back to dry.
4. Disable pass-through or quit: previous default output is restored.
5. Pass-through + Music + YouTube: matching locks; stop YouTube → unlock and catch up.

## Phase scope

**Included:** menu-bar status item, DAC pin, Music SB detection, exclusive-Music lock, BlackHole pass-through hop, one-band test EQ gain slider.

**Out of scope (next slices):** multi-band PEQ UI, sine sweep, Fixed mode UI, first-party ASP (remove Input prompt).
