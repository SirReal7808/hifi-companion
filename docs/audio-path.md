# Audio path

How SB matching, Pass-through, PEQ, and sweep actually work. Matching-only (Pass-through off) never enters the DSP path. Regressions in this area are listed in [pitfalls.md](pitfalls.md).

## Output (since R2a)

The equalizer and SB matching act on the **macOS output** (`AppModel.outputDevice`), unless it is a virtual / loopback device (`VirtualDeviceCatalog`; those are never processed or reclocked, and are hidden from the device list).

- **Preferred device** (menu → Output): `OutputPolicy` makes it the macOS output only at launch, when the user picks it, and when it is plugged in. A later manual switch in the macOS Sound menu is respected. "System Default" clears the preference. The old pinned DAC migrates to the preferred device.
- `OutputMonitor` listens for macOS output changes, device plug / unplug, and wake from sleep. On an output change the tap moves to the new device and that device's SB is matched.
- **Parametric Equalizer switch** (`isPassThroughEnabled`, persisted on explicit toggle). While it is on, the bridge may be briefly down — output change, wake, exclusive player, SB rebuild — and `reconcilePassThroughFormatIfNeeded` re-attaches it (throttled to every 5 s on failure). Quitting keeps the switch for the next launch.
- **Exclusive (hog-mode) players:** `AudioDeviceManager.hogModeOwner` names the app; the equalizer suspends ("Unavailable — Qobuz exclusive") and re-attaches when the player releases the device.

The app switches the macOS output only to the user's preferred hardware device ([redesign-0.3.md](redesign-0.3.md#output)), never to a virtual / loopback device.

## SB matching (Apple Music mode)

1. `MusicFormatDetector` tails `log stream` (`LogStreamReader` + `FormatParser`) and falls back to AppleScript (`AppleScriptFallback`) when logs are quiet. `MusicTrackMonitor` reports track changes.
2. `FormatSwitchGate` decides whether a detection is applied: prefer higher-trust sources (ALAC input over AudioQueue / audioCapabilities), require detections newer than the last switch, and after an upswitch ignore lower-rate detections for a **settle window (3 s)** unless Music reported a track change. This stops flapping detections from reclocking the DAC.
3. `DeviceAudioClientProbe` lists processes with running output on the DAC. Music, our own process, and a short system-UI ignore list (Control Center, notifications, Spotlight, Dock, …) are not competitors. Silent apps do not count.
4. `ExclusiveMusicLock` locks after another app has been audible for `lockGrace` (0.85 s) and unlocks after it has been silent for `unlockGrace` (0.6 s). While locked, new SB applies are skipped and the menu shows **Locked**. On unlock the latest accepted detection is applied (catch-up).
5. `PhysicalFormatChooser` + `AudioDeviceManager` set the DAC's physical format.

Behavior in one line each:

- Music alone → match as usual.
- Any other audible client on the DAC → lock; ignore new applies.
- Others stop, Music alone again → unlock and catch up.

Matching applies to the **real DAC** whether Pass-through is on or off, and the lock is always evaluated on the real DAC.

A rate change reclocks the DAC: a brief dropout at track start is normal and some DACs click.

### SB change while Pass-through is on

Before changing the DAC format, the tap and aggregate are stopped (an old-rate IOProc running into a reclocked device crackles). Then: apply DAC format → wait for the DAC to report it (≤ 1.2 s) → rebuild tap / IOProc at the new rate, preserving PEQ state.

`PassThroughBridge.graphMismatchesDAC` also catches rates that change under a live graph (external changes, late settles) and schedules a debounced rebuild. While rebuilding, `isPassThroughRebuilding` is set: a poll that sees the bridge down must **not** clear Pass-through or show an error. `--smoke-rate-eq` covers this.

## Pass-through (process tap → DAC)

Implemented in `PassThroughBridge`. Requires macOS 14.2+.

1. `CATapDescription` of other processes' output destined for the pinned DAC UID, **excluding our pid**.
2. `muteBehavior = .mutedWhenTapped` — apps' **direct** DAC output is silenced; we play the tap ourselves.
3. Private aggregate: DAC (main sub-device) + tap with drift compensation. `AudioDeviceCreateIOProcIDWithBlock` with a **nil** queue (binding the IOProc to the control `DispatchQueue` deadlocked / never fired).
4. Start with `AudioDeviceStart(aggregate, procID)` — **not** `AudioDeviceStart(aggregate, nil)`.
5. IOProc: copy tap samples to output (only when the tap delivered real input), mix the optional menu test tone, mix sweep, run `PEQProcessor` in place (Float32, **no heap allocation** in the callback).
6. **Signal** meter is tap RMS (`PassThroughMeter.capturePeakRMS`). Hearing threshold ≈ 0.004. It is **not** the sweep or the 880 Hz menu test tone.
7. Disable / quit destroys tap + aggregate. Apps unmute and play directly to the DAC. No double audio if you disable Pass-through without restarting Music.

**How it should sound:** start Music (or YouTube) on the DAC **first**. Enable Pass-through **without restarting Music**. Menu: `Process tap → DAC (…)` and **Signal: hearing audio**. Disable → direct playback returns.

### Permission (not the microphone)

The first enable shows **System Audio Recording** (System Settings → Privacy & Security → Screen & System Audio Recording). That lets the process tap hear other apps. It is not the laptop microphone, and audio is not saved. The prompt cannot be skipped on the tap path. `NSAudioCaptureUsageDescription` explains it.

Do **not** gate Pass-through on `AVAudioApplication.recordPermission` / Microphone TCC. That was a BlackHole-era footgun (the menu said "Input access denied" while Settings showed Microphone on, because Debug and `~/Applications` builds had different code signatures). There is no `NSMicrophoneUsageDescription`; users should never see a Microphone prompt.

TCC permission is tied to the binary's path and signature. That is why the app is always installed to `~/Applications/HiFiCompanion.app` (see the install steps in [AGENTS.md](../AGENTS.md)); a build launched from elsewhere is a different TCC row.

A bundled virtual device (DriverKit / first-party Audio Server Plug-in) is a **later** goal so capture might not need a prompt. Until then: process tap only. Do not bring BlackHole back as the hop.

### Why BlackHole was removed

Switching the system default to BlackHole does **not** retarget Music / Chrome streams already playing to the DAC. Those streams died; only an in-process test tone was audible. The process tap leaves apps on the DAC and copies their samples. `AppModel` still clears legacy "previous default device" keys from those builds on launch.

## PEQ

`PEQProcessor` (`PEQEngine.swift`) holds up to 10 `PeakingBiquad`s (PK / LS / HS, RBJ cookbook) plus output gain.

- Disabled or audibly flat bands (`|G| < 0.05 dB`) are skipped.
- **Bypass EQ** skips the biquads; with **Gain Match** on, output gain still applies so A/B loudness matches. Gain Match off = true dry (unity).
- **Auto** output gain lowers the trim when the cascade's peak boost would clip (≈ 0.5 dB headroom). Raises happen only through Auto / Set-safe / Reset ramps (~2 s); lowering is immediate.
- `AppModel.pushPEQToBridge` pushes live state onto the bridge. Matching-only stays dry.
- The graph curve is `PEQHeadroom.responseCurveDB` (same math as the DSP magnitudes).
- Status shows EQ **active** / not bit-perfect when any enabled band colors the signal on a running bridge.

Dry Pass-through is a shared Core Audio hop, not exclusive bit-perfect I/O. Active EQ is intentionally colored.

## Sweep

`SweepOscillator`: press-drag on the graph. Default −12 dB, range −20…0 dB. Mixed **before** PEQ so Bypass A/B applies to the tone.

**Cold aggregate:** aggregate IO only runs while a tapped app produces audio. Our pid is excluded from the tap, so a sweep mixed only in the IOProc is **silent** until Music is playing.

**Fix we keep:** if aggregate IO is not warm (no render in the last 0.5 s), `beginSweepTone` starts a short-lived `AVAudioEngine` → pinned DAC (`dacWakeEngine`) and applies PEQ in its source-node callback. `endSweepTone` / `hardMuteSweepTone` **stop and detach** it.

**Cold-DAC delay (known, hardware):** with nothing playing, the first ~0.5–1 s of a sweep can be silent. The engine itself starts in ~57 ms (measured on the DX5 II, 2026-10-28); the DAC mutes its output briefly when a stream starts from idle (anti-pop). With Music playing the sweep is instant. A quick click still sounds: the release waits until the engine has been audible for 150 ms.

**Must not:** start that engine at Pass-through enable or leave it running. A live engine on the same DAC contends with the aggregate and **silences Music**. `--smoke-sweep` expects engine idle → on during the gesture → off after.

FIX PEAK / FIX DIP add a peaking band at the parked needle: **cut** −3 dB / **boost** +3 dB, Q 3. If a peaking band already sits within ~4 % of that frequency, it is updated instead.

## Troubleshooting silence

1. A hardware DAC is pinned (not a virtual device).
2. System Audio Recording is allowed for **this** binary (`~/Applications/HiFiCompanion.app`).
3. Music was already playing on the DAC, then Pass-through was enabled (do not restart Music to "fix" routing).
4. **Signal:** follows Music / YouTube, not the test tone or sweep.
5. The menu test tone proves the playback mix only. Tone works + Signal silent ⇒ tap or permission failed.
6. Music dies after using the sweep: check that `dacWakeEngine` is not still running (`isDACSweepEngineRunningForAutomation`).
7. After an SB change: `graphSampleRate` must match the DAC; otherwise the rebuild is stuck.
