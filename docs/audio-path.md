# Audio path

How Pass-through, SB matching, PEQ, and sweep actually work in this repo. Matching-only (PT off) never enters the DSP path.

## Pin the DAC

`AppModel` lists hardware outputs via `AudioDeviceManager`. `VirtualDeviceCatalog` **excludes** BlackHole / Soundflower / Loopback / our private aggregate from the pin list. Pin is stored in UserDefaults. Pass-through requires a pinned **hardware** DAC.

The app does **not** change the system default output. Apps keep targeting the real DAC.

## SB matching (Apple Music mode)

1. `MusicFormatDetector` tails `log stream` (`LogStreamReader` + `FormatParser`) and falls back to AppleScript (`AppleScriptFallback` / `MusicTrackMonitor`) when logs are quiet.
2. `FormatSwitchGate` waits a settle window (~3 s) so flapping detections do not reclock the DAC every second.
3. `DeviceAudioClientProbe` lists processes with running output on that device. Music + self + a short system-UI ignore list are not competitors.
4. `ExclusiveMusicLock` locks after `lockGrace` if someone else is audible; unlocks after `unlockGrace` when they stop. While locked, new format applies are skipped; the menu shows **Locked**.
5. `PhysicalFormatChooser` + `AudioDeviceManager` set the DAC’s nominal rate/bits.

Lock is always evaluated on the **real DAC**, PT on or off.

When PT is on and the DAC rate changes, `PassThroughBridge.graphMismatchesDAC` triggers a rebuild: stop tap → apply DAC format → settle → new tap/IOProc at the new rate, preserving PEQ state. A poll that sees the bridge down **during** rebuild must not clear PT (`isPassThroughRebuilding`). `--smoke-rate-eq` covers this.

## Pass-through (process tap → DAC)

Implemented in `PassThroughBridge`. Requires macOS 14.2+.

1. `CATapDescription` of other processes’ output destined for the pinned DAC UID, **excluding our pid**.
2. `muteBehavior = .mutedWhenTapped` — apps’ **direct** DAC output is silenced; we play the tap ourselves.
3. Private aggregate: DAC (main) + tap. `AudioDeviceCreateIOProcIDWithBlock` with a **nil** queue (binding the IOProc to the control `DispatchQueue` deadlocked / never fired).
4. Start with `AudioDeviceStart(aggregate, procID)` — **not** `AudioDeviceStart(aggregate, nil)`.
5. IOProc: copy tap samples to output (require non-empty tap input), mix optional menu test-tone, mix sweep, run `PEQProcessor` in place (interleaved Float32, **no heap allocation** in the callback).
6. **Signal** meter is tap RMS (`PassThroughMeter.capturePeakRMS`). Hearing threshold ≈ 0.004. It is **not** the sweep or the 880 Hz menu beep.
7. Disable / quit destroys tap + aggregate. Apps unmute and play directly to the DAC. No double audio if you disable PT without restarting Music.

**How it should sound:** start Music (or YouTube) on the DAC **first**. Enable Pass-through **without restarting Music**. Menu: `Process tap → DAC (…)` and **Signal: hearing audio**. Disable → direct playback returns.

### Permission (not the microphone)

First enable shows **System Audio Recording** (`NSAudioCaptureUsageDescription`). That lets the process tap hear other apps. It is not the laptop mic; audio is not saved. The dialog cannot be skipped on the tap path.

Do **not** gate PT on `AVAudioApplication.recordPermission` / Microphone TCC. That was a BlackHole-era footgun (menu said “Input access denied” while Settings showed Microphone On, because Debug vs `~/Applications` had different CDHashes). There is no `NSMicrophoneUsageDescription`. Users should not see a Microphone prompt.

A bundled virtual device (DriverKit / first-party ASP) is a **later** goal so capture might not need a prompt. Until then: process tap only. Do not bring BlackHole back as the hop.

### Why BlackHole was removed

Switching the system default to BlackHole does **not** retarget Music/Chrome already playing to the DX5. Those streams died; only an in-process test tone was audible. Process tap leaves apps on the DAC and copies their samples.

## PEQ

`PEQProcessor` (`PEQEngine.swift`) holds up to 10 `PeakingBiquad`s (PK / LS / HS, RBJ) plus output gain.

- Disabled / audibly flat bands (`|G| < 0.05 dB`) are skipped.
- **Bypass EQ** skips biquads; **Gain Match** still applies output gain so A/B loudness matches.
- Auto output gain lowers trim when cascade peak boost would clip (≈ 0.5 dB headroom). It does not raise except via the explicit Auto / Set-safe ramps.
- `applyPEQ` from `AppModel` pushes live state onto the bridge. Matching-only (PT off) stays dry.
- Graph curve is `PEQHeadroom.responseCurveDB` (same math as DSP magnitudes).
- Status: EQ **active** / not bit-perfect when any enabled band colors the signal on a running bridge.

Dry pass-through is a shared Core Audio hop, not exclusive bit-perfect I/O. Active EQ is intentionally colored.

## Sweep

`SweepOscillator`: press-drag on the graph. Default −12 dB, clamp −20…0. Mixed **before** PEQ so Bypass A/B applies to the tone.

**Cold aggregate:** IO only schedules while a tapped app produces audio. Our pid is excluded, so Sweep mixed only in the IOProc is **silent** until Music is playing.

**Fix we keep:** if aggregate IO is not warm, `beginSweepTone` starts a short-lived `AVAudioEngine` → pinned DAC (`dacWakeEngine`), applying PEQ in that source-node callback. `endSweepTone` / `hardMute` **stop and detach** it.

**Must not:** start that engine at PT enable and leave it running. A live engine on the same DAC contends with the aggregate and **silences Music**. `--smoke-sweep` expects engine idle → on during gesture → off after.

Peak / Dip add a band at the parked needle (cut / boost, Q = 3).

## Install / TCC

Always:

```bash
ditto "build/Build/Products/Release/HiFiCompanion.app" ~/Applications/HiFiCompanion.app
open ~/Applications/HiFiCompanion.app
```

Launch log: `stamp=eq-footer-compact-v4 ver=19 exe=…/Applications/HiFiCompanion.app/…`. Different paths = different TCC rows. Spotlight will launch a stale Applications copy.

## Troubleshooting silence

1. Hardware DAC pinned (not a virtual device).
2. System Audio Recording allowed for **this** binary.
3. Music already playing on the DAC, then enable PT (do not restart Music to “fix” routing).
4. **Signal:** must follow Music/YouTube, not Test tone / Sweep.
5. Menu test tone proves the playback mix only. Tone works + Signal silent ⇒ tap/permission failed.
6. If Music dies when Sweep has been used: confirm `dacWakeEngine` is not still running (`isDACSweepEngineRunningForAutomation`).
7. After an SB change: confirm `graphSampleRate` matches the DAC; otherwise rebuild is stuck.
