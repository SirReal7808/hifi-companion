# HiFi Companion

macOS menu-bar app that matches your pinned external DAC’s sample rate and bit depth (SB) to the track currently playing in Apple Music, with an optional **Pass-through** path that can apply a one-band test EQ while you listen.

Phase 1 focus: Music SB matching, exclusive-Music lock, process-tap Pass-through, and a **one-band test EQ** (gain slider). Full multi-band PEQ UI and sweep come later.

**Requirements:** macOS 14.2+ (process tap), Xcode 15+, Apple Music. Not sandboxed and not intended for the Mac App Store (`log stream` needs unsandboxed access).

## Pass-through (process tap → DAC)

Pass-through uses a **Core Audio process tap** (`CATapDescription` + `AudioHardwareCreateProcessTap`) of other processes’ output destined for the pinned DAC, with `muteBehavior = mutedWhenTapped` so their direct DAC output is silenced while we play the tapped audio (plus optional EQ) ourselves.

- Does **not** change the system default output.
- Pins playback to the hardware DAC only.
- Excludes HiFi Companion’s own pid so the tap does not feedback.
- **Signal** meter is tap RMS from Music / Chrome / etc. — not the Test tone.
- SB matching stays on the **real DAC** (apps keep targeting it).

No virtual loopback driver is required.

**How it should sound:** Start Music (or YouTube) on the DX5 **first**. Enable Pass-through **without restarting Music**. You keep hearing Music on the DAC through the tap; the menu shows `Process tap → DAC (DX5 II) · EQ bypass` and **Signal: hearing audio**. Disable Pass-through → direct playback returns, no double audio.

Menu toggle **Pass-through**:

1. Requires a **pinned hardware DAC**.
2. Creates a private process tap of other apps → that DAC (excluding our pid).
3. Builds a private aggregate (DAC + tap) and runs an IOProc: tap → optional EQ → DAC.
4. On disable or quit: destroys the tap/aggregate. Apps unmute and play directly to the DAC again.

### System Audio Recording permission

The first time Pass-through starts, macOS may show a **System Audio Recording** (or Screen & System Audio Recording) prompt. That grants HiFi Companion permission to tap other apps’ audio for the live DAC path — it is **not** the laptop microphone, and nothing is recorded to disk. Allow HiFi Companion under System Settings → Privacy & Security. Denial shows a clear Settings error in the menu; never treat Test tone as proof that capture works.

### Silent DAC troubleshooting

1. Confirm a hardware DAC is pinned.
2. Allow **System Audio Recording** for HiFi Companion if prompted.
3. Leave Music playing on the DAC, then enable Pass-through (do not restart Music to “fix” routing).
4. Check **Signal:** — it must reflect Music/YouTube, not Test tone.
5. **Test tone to DAC** only proves the playback mix; if tone works but Signal stays silent while Music plays, the tap/permission path failed.

**Stable binary / TCC:** Prefer one install path:

```bash
mkdir -p ~/Applications
rm -rf ~/Applications/HiFiCompanion.app
ditto "build/Build/Products/Release/HiFiCompanion.app" ~/Applications/HiFiCompanion.app
open ~/Applications/HiFiCompanion.app
```

## Apple Music mode

Apple Music mode switches SB on the Music-facing device **only while Music is the sole app sending audio there**.

- Music alone → match as usual on the pinned / default DAC.
- Any other audible client on that DAC → **lock**: keep the current format; ignore new applies until unlocked. Menu bar shows **Locked**.
- When others stop and Music is alone → **unlock** and catch up.
- Silent apps do not lock. Short system chirps are softened with grace + an ignore list.

With process-tap Pass-through **on** or **off**, lock is evaluated on the **real DAC** (apps still target it).

## Test EQ (one peaking band)

Only while **Pass-through** is on (matching-only stays dry):

1. Menu → **Test EQ…** opens a floating panel with a gain slider.
2. Fixed band: **1 kHz peaking**, Q ≈ **1.41**.
3. Drag **Gain** (−12…+12 dB). At **0 dB** / **Bypass**, EQ is off and the path is dry. When gain ≠ 0, the menu shows EQ **active** — the path is **not bit-perfect**.

### Honest limits

- Dry pass-through is a **shared Core Audio hop**, not exclusive bit-perfect I/O. Active EQ is intentionally colored DSP.
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

Keep launching the **same** `~/Applications/HiFiCompanion.app` so the System Audio Recording TCC row matches the binary you run.

## Run

- Menu-bar agent (`LSUIElement`): no Dock icon.
- Pin your real DAC.
- Enable **Pass-through** while Music is already playing on that DAC.
- Quit from the menu (tears down the tap).

## Test checklist

1. Music alone, matching only: 44.1 ↔ 96 follows in Audio MIDI Setup.
2. Music already playing on the DAC → enable Pass-through (no Music restart) → hear Music on the DAC; Signal hearing; default output still the DAC.
3. **Test EQ…** → boost gain → hear the 1 kHz band; set 0 dB / Bypass → dry.
4. Disable Pass-through → direct playback returns; no double audio.
5. Pass-through + Music + YouTube: matching locks on the DAC; stop YouTube → unlock and catch up.

## Phase scope

**Included:** menu-bar status item, DAC pin, Music SB detection, exclusive-Music lock, process-tap Pass-through, one-band test EQ gain slider.

**Out of scope (next slices):** multi-band PEQ UI, sine sweep, Fixed mode UI, DriverKit / first-party ASP.
