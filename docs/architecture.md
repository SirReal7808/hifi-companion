# Architecture

How the app is put together: process model, data flow, source map, persistence, automation hooks, and tests. The audio details live in [audio-path.md](audio-path.md); the EQ window spec in [eq-window.md](eq-window.md).

## Overview

```
Apple Music / Chrome / …  ──plays to──►  pinned hardware DAC
                                      ▲
MusicFormatDetector (log stream + AppleScript fallback)
        │
        ▼
FormatSwitchGate + ExclusiveMusicLock ──► AudioDeviceManager sets DAC SB
        │
        ▼  Pass-through ON
CATapDescription (exclude our pid, mutedWhenTapped)
        │
        ▼
private aggregate (DAC + tap) + IOProc
        │
        ├─ tap RMS → Signal meter (not the sweep / test tone)
        ├─ optional menu test-tone mix
        ├─ SweepOscillator mix (before PEQ so Bypass A/B colors the tone)
        ├─ PEQProcessor (10 biquads + output gain, realtime, no heap in IOProc)
        └─ DAC output
```

**Matching-only** (Pass-through off) is dry: no tap, no PEQ. EQ window controls require Pass-through (or `--eq-unlock-controls` for UI tests).

## Process model

- `HiFiCompanionApp` is a SwiftUI `MenuBarExtra` (`.menu` style) whose label is `AppModel.statusTitle`. `AppDelegate` sets the accessory activation policy, starts the model, prints the launch stamp, and runs automation flags.
- `AppModel.shared` is the single `@MainActor` `ObservableObject` the views observe. It owns device state, matching, the exclusive lock, Pass-through, the sweep gesture, and appearance. The EQ itself (bands, output gain / headroom, profiles, undo / redo, persistence) lives in `PEQDocument`, exposed as `model.peq`; `AppModel` applies its side effects (push to the DSP, status text, sweep level) through `PEQDocument.onChange` and republishes its changes to the views.
- A **0.4 s poll** refreshes devices, the pinned device format, the exclusive lock, the bridge running flag, the Signal meter, and DAC-rate drift. Every `@Published` write there is equality-guarded (unconditional writes re-rendered the EQ window ~2.5×/s; see [pitfalls.md](pitfalls.md)).
- Music detection streams on a background `Task` and hops to the main actor per detection.
- The EQ window is an AppKit `NSWindow` (`ExactHeightEQPanel`) hosting `PEQView` via `NSHostingController`, managed by `PEQPanelController`. `MenuBarExtra` `.menu` cannot host it reliably, so menu actions defer to the next main-queue turn and open it.
- `PassThroughBridge` owns the tap, private aggregate, IOProc, `PEQProcessor`, `SweepOscillator`, and the short-lived sweep wake engine. Its control state is serialized on a private `DispatchQueue`; the IOProc runs on Core Audio's thread.

## Source map

| File | Role |
|---|---|
| `HiFiCompanion/HiFiCompanionApp.swift` | `@main`, `MenuBarExtra` with `StatusMenuView` |
| `HiFiCompanion/AppDelegate.swift` | Accessory policy, launch stamp, automation flags / smokes |
| `HiFiCompanion/AppModel.swift` | Menu state, pin, PT toggle + rebuild, sweep gesture, exclusive lock, poll; owns `peq` |
| `HiFiCompanion/Audio/PEQDocument.swift` | EQ document: bands, output gain / Auto headroom / ramps, bypass, sweep level and needle, FIX PEAK / DIP, profiles, undo / redo (with continuous-edit coalescing), persistence |
| `HiFiCompanion/StatusMenuView.swift` | Menu bar UI |
| `HiFiCompanion/PEQView.swift` | EQ window: toolbar, graph, band list, side glass + knobs, footer chips |
| `HiFiCompanion/PEQPanelController.swift` | `PEQPanelMetrics` (H(N) layout), `ExactHeightEQPanel`, window chrome, build stamp |
| `HiFiCompanion/Audio/PassThroughBridge.swift` | Process tap + private aggregate + IOProc; sweep wake engine; test tone; meter |
| `HiFiCompanion/Audio/PEQEngine.swift` | `PEQHeadroom` (response curve, peak boost, Auto / Set-safe / Reset math) + `PEQProcessor` (realtime) |
| `HiFiCompanion/Audio/PeakingBiquad.swift` | RBJ peaking / low-shelf / high-shelf biquad, interleaved realtime processing |
| `HiFiCompanion/Audio/SweepOscillator.swift` | Phase-continuous sweep tone, −20…0 dB, default −12 |
| `HiFiCompanion/Audio/EQBand.swift` | Band model and limits (max 10 bands, 20 Hz–20 kHz, ±14 dB, Q 0–10) |
| `HiFiCompanion/Audio/EQFormat.swift` | Frequency strings and **unsigned-zero** dB strings |
| `HiFiCompanion/Audio/EQProfile.swift` | Named profiles + JSON profile store |
| `HiFiCompanion/Audio/PEQHistory.swift` | Undo / redo snapshots |
| `HiFiCompanion/Audio/ExclusiveMusicLock.swift` | Lock / unlock with grace periods |
| `HiFiCompanion/Audio/DeviceAudioClientProbe.swift` | Audible output clients on the DAC; system-UI ignore list |
| `HiFiCompanion/Audio/AudioDeviceManager.swift` | Device listing, formats, default device, apply SB |
| `HiFiCompanion/Audio/PhysicalFormatChooser.swift` | Pick the DAC physical format for a requested SB (exact bit depth first; 16-bit packs into a 24-bit container rather than downconverting) |
| `HiFiCompanion/Audio/AudioFormatInfo.swift` | SB value type + display strings |
| `HiFiCompanion/Audio/AudioOutputDevice.swift` | Output device value type |
| `HiFiCompanion/Audio/VirtualDeviceCatalog.swift` | Recognize virtual loopbacks / our aggregate (pin exclusion only) |
| `HiFiCompanion/Detection/MusicFormatDetector.swift` | Combines `log stream` detection with the AppleScript fallback |
| `HiFiCompanion/Detection/LogStreamReader.swift` | Tails `log stream` for Music |
| `HiFiCompanion/Detection/FormatParser.swift` | Parses Music log lines into SB detections |
| `HiFiCompanion/Detection/FormatSwitchGate.swift` | Settle / priority rules before applying a detection |
| `HiFiCompanion/Detection/DetectionSource.swift` | Detection sources and trust order (ALAC input > AudioQueue > audioCapabilities > AppleScript) |
| `HiFiCompanion/Detection/AppleScriptFallback.swift` | AppleScript query of the current Music track |
| `HiFiCompanion/Detection/MusicTrackMonitor.swift` | Music / iTunes distributed player-info notifications (track changes) |

## Persistence

`UserDefaults` (domain `com.hificompanion.app`):

| Key | Content |
|---|---|
| `pinnedOutputDeviceUID` | Pinned DAC UID |
| `peqBandsJSON` | Used bands (JSON) |
| `peqOutputGainDB`, `peqAutoOutputGain`, `peqBypass`, `peqBypassGainMatch` | Output / bypass state |
| `peqToneLevelDB`, `peqSweepNeedleHz` | Sweep level and parked needle |
| `peqClippingWarning` | Last clipping-risk flag |
| `appearancePreference` | System / Light / Dark |
| `passThroughPreviousDefaultUID`, `passThroughPreviousDefaultInputUID` | Legacy (BlackHole era); cleared on launch |

Profiles: `~/Library/Application Support/HiFiCompanion/eq-profiles.json`.

## Automation flags

Pass these to the app binary (e.g. `~/Applications/HiFiCompanion.app/Contents/MacOS/HiFiCompanion --show-eq`). Output goes to stdout.

| Flag | What it does |
|---|---|
| `--show-eq` | Open the EQ window and print `EQ_OPEN:` sizing |
| `--eq-unlock-controls` | With `--show-eq`: enable controls without Pass-through |
| `--eq-enable-pt` | With `--show-eq`: also start Pass-through |
| `--eq-screenshot <path>` | With `--show-eq`: capture the EQ window (own process, no Screen Recording permission) |
| `--eq-add-one`, `--eq-delete-one` | Add / remove one band and verify height (`EQ_ADD_ONE` / `EQ_DELETE_ONE`) |
| `--eq-stress-bands` | Grow to 10 bands then shrink to 4, checking H(N) each step; optional `--eq-screenshot-8/-10/-4 <path>` |
| `--smoke-passthrough` | Headless Pass-through check (tap RMS, not the test tone) |
| `--smoke-rate-eq` | PT on → change DAC rate → graph must rebuild and PEQ stay live |
| `--smoke-sweep` | Sweep wake engine: idle → on during gesture → off after |
| `--smoke-test-eq-ui` | PT on → open EQ → set 1 kHz gain → verify live state |
| `--hold-passthrough-seconds <n>` | Enable PT and print meter lines for `n` seconds |

Automation that opens the app runs a second `AppModel` against the real DAC. Do not run it while Mert is listening, and never start Music / YouTube for it.

## Tests

98 unit tests, hosted in the app (`@testable import HiFiCompanion`); the hosted app does not start its services under XCTest:

| Test file | Covers |
|---|---|
| `PEQPanelMetricsTests` | H(N) layout, screen clamp, **compact footer invariant** |
| `PEQHeadroomTests` | Peak boost, Auto / Set-safe / Reset output gain, ramps |
| `PeakingBiquadTests` | PK / LS / HS magnitudes, interleaved processing |
| `SweepOscillatorTests` | Level clamp, default −12 dB, phase continuity, release fade |
| `FormatParserTests`, `FormatSwitchGateTests` | Music log parsing, settle / priority rules |
| `ExclusiveMusicLockTests` | Lock / unlock grace |
| `PEQDocumentTests` | EQ document: edits, undo / redo, knob-run coalescing, graph drag, FIX PEAK / DIP, Auto headroom, profiles, persistence and legacy migration |
| `EQProfileStoreTests`, `PEQHistoryTests` | Profile store, undo / redo stacks |
| `LineSplitterTests` | `log stream` line reassembly across reads (incl. split UTF-8) |
| `EQFormatTests` | Unsigned zero dB strings, frequency strings, Q floor |
| `VirtualDeviceCatalogTests` | Loopback / aggregate recognition |

## Project configuration

- **XcodeGen**: `project.yml` is the source of truth; `HiFiCompanion.xcodeproj` is generated. Never hand-edit `project.pbxproj`.
- **Versions**: `MARKETING_VERSION` / `CURRENT_PROJECT_VERSION` in `project.yml`; `Info.plist` reads them via `$(…)`.
- **Bundle id** `com.hificompanion.app`; `LSUIElement`; `LSMinimumSystemVersion` 14.2.
- **Entitlements**: App Sandbox off (needed for `log stream`), Apple Events automation on (AppleScript fallback). Hardened runtime on.
- **Usage strings**: `NSAudioCaptureUsageDescription` (System Audio Recording for the process tap) and `NSAppleEventsUsageDescription`. There is deliberately **no** `NSMicrophoneUsageDescription`.
