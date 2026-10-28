# Handoff brief

Read [AGENTS.md](../AGENTS.md) first. This is the durable product/architecture brief so you can continue from this clone + GitHub only.

## Product

**HiFi Companion** is a macOS menu-bar agent (`LSUIElement`, no Dock icon). It:

1. Pins a **hardware DAC** and matches that device’s **SB** (sample rate + bit depth) to the track playing in Apple Music.
2. **Locks** matching while any other audible app is on that DAC; unlocks when Music is alone again.
3. Optionally **Pass-through**: a Core Audio **process tap** of other apps targeting the DAC → private aggregate IOProc → optional **PEQ** → same DAC. Direct app output is muted while tapped (`mutedWhenTapped`).
4. Opens a floating **EQ** window: used bands only (max 10, PK / LS / HS), response graph, press-drag **sine sweep**, Peak (cut) / Dip (boost), profiles, undo/redo.

It is **not** a music player. No internet radio, discovery, or lyrics. Stops at macOS until Mert asks for Android. Share filter math later; do not share the Mac audio driver.

Repo: https://github.com/SirReal7808/hifi-companion  
User: **Mert**. Chat with Mert in Turkish; product UI and everything in the repo are English.

## Current line

Work from **`cursor/eq-fit-laptop-970c`** (includes this pack: `AGENTS.md`, `docs/`). Default **`main` is stale** — older matching + 10-band PEQ without the glass EQ window. Never start there.

Tag **`v0.2`** (`a49ad4b`) is the **app** snapshot only (approved EQ binary). It does **not** contain onboarding docs. `git checkout v0.2` drops this pack.

| | |
|---|---|
| Work from | `cursor/eq-fit-laptop-970c` |
| App tag | `v0.2` at `a49ad4b13be7c58d53c3a72f3e6c25665f385df4` — rollback only; no docs |
| Stamp | `eq-footer-compact-v4` |
| Version | `0.2.0 (19)` — single source in `project.yml` (`MARKETING_VERSION` / `CURRENT_PROJECT_VERSION`); `Info.plist` reads them; confirm with launch log `ver=` |
| Binary | `~/Applications/HiFiCompanion.app` (keep `HiFiCompanion-0.2.app` as archive) |

Open GitHub PRs (unmerged as of this pack):

- [#1](https://github.com/SirReal7808/hifi-companion/pull/1) `cursor/eq-visual-glass-2953` → `main`
- [#2](https://github.com/SirReal7808/hifi-companion/pull/2) `cursor/eq-fit-laptop-970c` → `#1`’s branch (laptop fit + compact footer + side knobs)

## Architecture

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

**Matching-only** (PT off) is dry: no tap, no PEQ. EQ panel controls require PT (or `--eq-unlock-controls` for UI tests).

**Sweep when the aggregate is cold:** our pid is excluded from the tap, so a self-client does not wake aggregate IO. Press-drag starts a **short-lived** `AVAudioEngine` → DAC, applies PEQ in that callback, and **must stop on release**. Leaving it running fights the aggregate and silences Music. See [audio-path.md](audio-path.md) and [pitfalls.md](pitfalls.md).

**Not in the path:** BlackHole, Soundflower, or any virtual loopback as a hop. `VirtualDeviceCatalog` only **excludes** those from the pin list. System default output stays on the DAC.

**Permission:** first PT enable shows **System Audio Recording** (Screen & System Audio Recording). That is **not** the laptop microphone. `NSAudioCaptureUsageDescription` explains this. Users should not see a Microphone prompt. A bundled first-party virtual device is a later release goal; until then the process tap is the capture path.

## Key files

| File | Role |
|---|---|
| `HiFiCompanion/AppModel.swift` | Menu state, pin, PT toggle, PEQ/sweep API, exclusive lock, polls |
| `HiFiCompanion/AppDelegate.swift` | Accessory app; launch stamp; `--show-eq` / smokes |
| `HiFiCompanion/StatusMenuView.swift` | Menu bar UI |
| `HiFiCompanion/PEQView.swift` | EQ window: graph, band list, side glass, knobs, footer chips |
| `HiFiCompanion/PEQPanelController.swift` | `ExactHeightEQPanel`, `PEQPanelMetrics`, traffic lights, no zoom |
| `HiFiCompanion/Audio/PassThroughBridge.swift` | Tap + aggregate IOProc + sweep wake engine |
| `HiFiCompanion/Audio/PEQEngine.swift` | `PEQHeadroom` + `PEQProcessor` |
| `HiFiCompanion/Audio/PeakingBiquad.swift` | RBJ peaking / LS / HS, interleaved realtime |
| `HiFiCompanion/Audio/SweepOscillator.swift` | Graph tone, −20…0 dB, default −12 |
| `HiFiCompanion/Audio/EQBand.swift` | Used-band model (max 10) |
| `HiFiCompanion/Audio/EQFormat.swift` | Frequency + **unsigned zero** dB strings |
| `HiFiCompanion/Audio/EQProfile.swift` | Named profiles |
| `HiFiCompanion/Audio/PEQHistory.swift` | Undo/redo |
| `HiFiCompanion/Audio/ExclusiveMusicLock.swift` | Lock/unlock grace |
| `HiFiCompanion/Audio/DeviceAudioClientProbe.swift` | Audible clients on the DAC |
| `HiFiCompanion/Audio/VirtualDeviceCatalog.swift` | Pin-exclusion only |
| `HiFiCompanion/Detection/MusicFormatDetector.swift` | `log stream` + AppleScript |
| `HiFiCompanion/Detection/FormatParser.swift` | Parse Music log lines |
| `HiFiCompanion/Detection/FormatSwitchGate.swift` | Settle window before apply |
| `HiFiCompanionTests/PEQPanelMetricsTests.swift` | Height + **compact footer invariant** |

## macOS / machine

Mert’s Mac runs **macOS 27**. Accessibility shows as Device Control and Data Access. Deployment target is 14.2+ (process tap). Not sandboxed; not App Store (`log stream` needs unsandboxed access). Prefer building and launching on the Mac yourself rather than asking Mert to run install steps.

## SB matching

Write **SB** in caps in chat and docs. Matching applies the detected Music format to the **real DAC** whether PT is on or off (apps still target the DAC).

- Music alone → match as usual.
- Any other audible client on that DAC → **lock** (menu: Locked); ignore new applies.
- Others stop, Music alone → **unlock** and catch up.
- Silent apps do not lock. Short system chirps: grace + ignore list in `DeviceAudioClientProbe`.
- Rate change reclocks the DAC: brief dropout at track start is normal; some DACs click. With PT on, rebuild the tap/aggregate at the new rate (`graphMismatchesDAC` / `--smoke-rate-eq`).

## Exclusive Music lock

`ExclusiveMusicLock`: competing audible clients must last past `lockGrace` (~0.85 s) before lock; after they stop, `unlockGrace` (~0.6 s) before unlock. Evaluated on the **real DAC**.

## Listening tests

Mert does listening tests himself (“müzik çalma testi”) until he says otherwise. **Do not start Music or YouTube** for those tests. You may use `afplay`, smokes, and `--show-eq` for engineering checks.

## Language

- Chat with Mert in **Turkish**; English technical terms are welcome.
- Product strings, code, comments, commit messages, and repo docs stay **English**.
- (The old “reply in English” rule was a Cursor workaround for weak Turkish output. It no longer applies.)
- “0.1/0.2 sürümüne geri dönelim” = restore that revert snapshot.

## Locked footer invariant (2026-10-27)

Approved at v0.2. Full rule: [`.cursor/rules/eq-compact-footer.mdc`](../.cursor/rules/eq-compact-footer.mdc). Visual: [eq-visual-target.md](eq-visual-target.md), shot [media/eq-footer-compact.jpg](media/eq-footer-compact.jpg).

1. No separate dark footer bar.
2. Add Band and Reset sit on the main window background.
3. Pad above those chips equals pad below (`footerChipInset` both sides; `footerClearance == 0`).
4. Right Output/Tone glass keeps bottom **rounded corners and drop shadow** fully visible — never `.clipped()` / compositing group / overlay / ExactHeight compression on the middle.
5. Window height hugs `max(band list, side glass) + compact chrome` (`sideShadowBleed == 0`).

`testCompactFooterInvariant` must stay green. If a layout change would violate this, **stop**.

## Revert commands

**v0.2** (approved compact footer + laptop fit + side UX) — [eq-v0.2-revert.md](eq-v0.2-revert.md). Prefer the archived binary so you keep this branch for docs:

```bash
open ~/Applications/HiFiCompanion-0.2.app
# restoring sources to the tag drops AGENTS.md/docs — then:
# git fetch origin cursor/eq-fit-laptop-970c && git checkout cursor/eq-fit-laptop-970c
```

**v0.1** (last good EQ **before** the side-panel UX rewrite, stamp `window-chrome-v7` / ver 7) — [eq-v0.1-revert.md](eq-v0.1-revert.md):

```bash
open ~/Applications/HiFiCompanion-0.1.app
# or:
git fetch origin tag v0.1 && git checkout v0.1
```

Do not delete those tags.

## What shipped vs what is next

**Shipped on v0.2:** menu pin + SB match + exclusive lock; process-tap PT; 10 used bands PK/LS/HS; graph + sweep + Peak/Dip; frosted-glass EQ; side knobs; ALL CAPS side labels; framed OUTPUT GAIN; compact footer; laptop `visibleFrame` clamp; profiles; undo/redo; Auto output-gain headroom; Bypass + Gain Match; per-band enable.

**Deferred / later:** Android capture+EQ; DriverKit / first-party virtual device (to drop any remaining capture prompt); band reorder motion; treating the sparse Liquid Glass light mock as a target (rejected).

**Honest limits:** dry PT is a shared Core Audio hop, not exclusive bit-perfect I/O. Active EQ is colored DSP. Status may say EQ active / not bit-perfect.

## How the EQ window got here (synthesis, not a task dump)

The glass EQ landed on PR #1, then laptop-fit + compact footer on PR #2. Along the way we repeatedly broke height (void under footer, Peak/Dip clipped, window taller than the laptop), CPU (PreferenceKey + poll republish), Pass-through silence (idle sweep engine + wrong `AudioDeviceStart`), launch SIGSEGV (throwaway `NSWindow.close()`), signed-zero dB, and a live green zoom button. Those fixes are the contract in [pitfalls.md](pitfalls.md). Do not re-litigate them.

## Build reminder

Always reinstall to `~/Applications/HiFiCompanion.app` after a pull. Spotlight will happily launch a stale copy. Confirm launch log `stamp=` / `ver=` / `exe=`.
