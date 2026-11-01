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

**Next-track preload (since build 35).** Apple Music decodes the next track ~20 s before the current one ends (gapless) and logs *its* format then; a 96 kHz line arrived at 379 s of a 402 s 44.1 kHz track and reclocked the DAC mid-track (~1.1 s gap, and the rest resampled). And a new track sometimes starts with no format line at all until something (a pause) makes Music log it again. So the playing track is checked with AppleScript (`sample rate of current track`, right for 44.1 and 96 kHz — verified 2026-10-31):

- A detected **rate change** applies now only if the playing track has that rate; otherwise it is **held** for the next track (`NextTrackGuard.decide`; log: `Held 96 kHz … for the next track`).
- On **Track changed** (asked at about 0.15, 0.4, 1 and 2 s — AppleScript can lag the notification) the DAC moves to the playing track's rate: the held format if its rate matches, else the rate AppleScript reports (`formatAtTrackChange`; log: `Track change → …`). Only an answer equal to the previous track's accepted rate can be stale; any other rate is applied at the first answer, even if the held detection disagrees (`shouldWaitForAppleScript`). A rate change still costs about 1 s of silence (DAC relock + tap restart) at the start of the new track.
- AppleScript unavailable (Music not running, error, or no answer within its 1 s timeout) → the old behavior (apply as detected).

A detection that would leave the DAC exactly as it is (same rate, same physical bit depth — e.g. a 16-bit and a 24-bit report of one track, both in the 24-bit container) while the tap already runs on that DAC at that rate is accepted **without** stopping or rebuilding anything (`PhysicalFormatChooser.isNoOpSwitch`, `AudioDeviceManager.plannedFormat`); the log says `unchanged — no rebuild`. It used to rebuild the tap, sometimes mid-track when a late second detection arrived.

### SB change while Pass-through is on

Before changing the DAC format, the tap and aggregate are stopped (an old-rate IOProc running into a reclocked device crackles). Then: apply DAC format → wait for the DAC to report it (≤ 1.2 s) → rebuild tap / IOProc at the new rate, preserving PEQ state.

`PassThroughBridge.graphMismatchesDAC` also catches rates that change under a live graph (external changes, late settles) and schedules a debounced rebuild. While rebuilding, `isPassThroughRebuilding` is set: a poll that sees the bridge down must **not** clear Pass-through or show an error. `--smoke-rate-eq` covers this.

## Pass-through (process tap → DAC)

Implemented in `PassThroughBridge`. Requires macOS 14.2+.

1. `CATapDescription` of other processes' output destined for the pinned DAC UID, **excluding our pid**.
2. `muteBehavior = .mutedWhenTapped` — apps' **direct** DAC output is silenced; we play the tap ourselves.
3. Private aggregate: DAC (main sub-device) + tap. Drift compensation by output transport (`TapClockPolicy`): **off** for hardware-clocked outputs (USB, built-in, HDMI, DisplayPort, Thunderbolt, FireWire, PCI) — it resampled the tap, see [Null test](#null-test); **on** for Bluetooth, AirPlay, aggregate, virtual and unknown outputs, whose clock the tap may not share. `AudioDeviceCreateIOProcIDWithBlock` with a **nil** queue (binding the IOProc to the control `DispatchQueue` deadlocked / never fired).
4. Start with `AudioDeviceStart(aggregate, procID)` — **not** `AudioDeviceStart(aggregate, nil)`.
5. IOProc: copy tap samples to output (only when the tap delivered real input), mix the test tone (smoke automation only; no UI since R5), mix sweep, run `PEQProcessor` in place (Float32, **no heap allocation** in the callback).
6. **Signal** meter is tap RMS (`PassThroughMeter.capturePeakRMS`). Hearing threshold ≈ 0.004. It is **not** the sweep or the 880 Hz test tone. Settings → Diagnostics shows it as the **Input level** meter (dBFS, pre-EQ).
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

## Null test

Does a flat equalizer change the audio? `scripts/null-test.sh` answers it bit for bit:

1. Quits the app (waits until it is gone) and starts the installed app with `open … --args --null-test <report>`, so the tap runs under the app's own System Audio Recording permission (none of the app's services, no user curve).
2. Writes a deterministic 24-bit stereo noise file (−48 dBFS peak, 0.3 s silence first) at the output's **current** rate, so macOS has no rate conversion to do.
3. Starts a fresh, flat `PassThroughBridge` (no bands, 0 dB output) on the current output, plays the file with `afplay`, and records what the IOProc hands the DAC (`NullTestRecorder`, preallocated, no allocation in the callback).
4. Compares the recording with the file (`NullTest.compare`: exact alignment, else cross-correlation) and prints `NULL_TEST: … → BIT-EXACT` or the null depth.
5. Three passes: flat with drift compensation **off** (normal use); four bands at 0 dB (the "audibly flat band" skip), also off; flat with drift compensation **on** (the old default, for comparison only). Then relaunches the app. A capture cut short never counts as bit-exact; the script passes when both normal-use passes are bit-exact.

**Result (2026-10-31, DX5 II, 44.1 kHz / 24-bit):** drift compensation **on** — every sample differed (macOS resampled the tap; null depth −10.6 dB on full-band noise, i.e. a fractional-sample shift, probably inaudible but not transparent); **off** — bit-exact, also with bands at 0 dB. Since then hardware-clocked outputs run the tap with drift compensation **off** (`TapClockPolicy`): the tap carries audio bound for the same DAC, so it shares that clock and has no drift to correct. Bluetooth / AirPlay / aggregate / virtual outputs keep it on (they may not share a clock and are not bit-perfect anyway). If clicks or dropouts ever appear over long listening, this is the first suspect (`PassThroughBridge.tapDriftCompensation`).

It is audible (soft noise, ~3 s three times) and needs silence from other apps: run it only when Mert says nobody is listening. The comparison logic is unit-tested (`NullTestTests`).

What it covers: tap → our IOProc → the buffer handed to the HAL. What it does not: the HAL's Float32 → DAC integer conversion and the DAC itself (the same as for any macOS playback).

## Dropouts and the audio log

`~/Library/Logs/HiFiCompanion/audio-events.log` (Settings → Diagnostics → Stream Health → Show in Finder; rotated to `.1` at 2 MB) has one timestamped line per event:

- App events: equalizer on / off, output changes, tap started (rate, channels, drift compensation, transport) / stopped / rebuilt (reason), sample rate / bit depth applied (with the track format and detection source), track changes, Apple Music Mode paused / resumed.
- IOProc stream health, polled once a second on the bridge queue (never written from the IOProc):
  - `DROPOUT: output skipped N frames` / `tap input skipped` — the cycle's sample time did not continue from the previous one inside a running stream (`IOContinuity`); a pause of ≥ 0.5 s is logged as `IO resumed`, not a dropout.
  - `DROPOUT: tap delivered short buffers` — fewer tap frames than the output needed (tail zero-filled).
  - `DROPOUT: macOS IO overload` — `kAudioDeviceProcessorOverload` on the aggregate.
  - `Slow cycles` — processing used more than half of the buffer time (a warning, not a dropout).

The IOProc only takes a lock when one of these happens. Reading a hiccup: no `DROPOUT` near its time means the break came before the tap (source, network buffering) or after the HAL (USB, DAC); a `Tap rebuild` or `Sample rate` line near it means a reclock (expected at track starts).

## Troubleshooting silence

1. A hardware DAC is pinned (not a virtual device).
2. System Audio Recording is allowed for **this** binary (`~/Applications/HiFiCompanion.app`).
3. Music was already playing on the DAC, then Pass-through was enabled (do not restart Music to "fix" routing).
4. **Signal:** follows Music / YouTube, not the test tone or sweep.
5. Input level stays at Silence while music plays ⇒ tap or permission failed. (The menu test tone was removed in R5: like the sweep, it is mixed in the IOProc, so it is silent while the aggregate is cold.)
6. Music dies after using the sweep: check that `dacWakeEngine` is not still running (`isDACSweepEngineRunningForAutomation`).
7. After an SB change: `graphSampleRate` must match the DAC; otherwise the rebuild is stuck.
