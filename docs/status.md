# Status and backlog

Where the project stands and what comes next. Every session reads this first and the `/handoff` skill updates it last, so the next session starts without the chat history. Keep it short and current: finished work moves to [releases.md](releases.md), decisions to the topic docs.

_Last updated: 2026-11-13 (PR #37 merged as `db57c1c`, build 40: EQ display drag fixed; 0.4.2 ready to release)._

## Now

- **Released:** 0.4.1 (build 36), tag `v0.4.1` → `c31580e`.
- **In development:** 0.4.2 — builds 37 (PR #33), 38 (PR #35), 39 + 40 (PR #37) all on `main`. Build 40 installed at `~/Applications/HiFiCompanion.app`.
- **PR #37:** Mert tested build 40 on 2026-11-13: ⌘Tab / Dock ✅, Save Profile… name ✅, EQ drag LG ↔ laptop stays under the pointer ✅. The merge landed (`db57c1c`) but GitHub's merge call returned 502 and the PR never showed as merged, so it was closed by hand with a note.
- **Waiting on Mert:** the 0.4.2 release OK. Branches: `main`, `spike/r4b-audibility-probe` (kept).

## Next up

1. **Release 0.4.2** (builds 37 + 38 + 39 + 40) with `/release` once Mert says so. Mert used build 37 daily 2026-11-01…12; `audio-events.log` (10–12 Nov) shows no stream breaks or tap errors.

## Backlog (not scheduled)

Small, Mert has not asked for them; propose before starting.

- **Null test at other rates.** Bit-exactness was measured at 44.1 kHz only (DX5 II). Run `scripts/null-test.sh` with the DAC at 96 kHz (and 48 kHz) when nobody is listening. Measurement only.
- **Format lines from other apps.** `LogStreamReader` takes `AudioQueue` lines from any process in `com.apple.coreaudio`; a bogus 48 kHz line (likely another app) was held as Music's next track on 2026-10-31 21:20. Harmless since build 36 (AppleScript decides at the track change), but filtering `AudioQueue` lines to Music would remove the noise. Needs `audio-path-reviewer`.
- **Code-review leftovers (2026-10-28, low):** `PEQView.swift` is 2,000 lines (split by component, no visual change); `isPassThroughFailure` classifies errors by text; logging mixes `print` and `os.Logger`; `project.yml` deployment target 14.0 vs the 14.2 the app needs; test target both hosted and compiling app sources.
- **Docs media:** no light-mode EQ screenshot.

## Later (Mert decides when)

- AutoEQ `ParametricEQ.txt` import / export; Auto EQ (Mert holds the details).
- Public release prep: Developer ID signing + notarization, app icon, updates.
- Windows / Android (maybe never).
- Bundled virtual device so capture needs no System Audio Recording prompt.

## Decided — do not re-propose

- Pausing / resuming Music around a rate switch: no. The ~1 s gap at the start of a track with a new rate is normal (2026-11-01).
- Audible-only exclusive lock: dropped; the ~10 s browser delay is accepted (README → Known behavior).
- Wiring the Apps exclusion list into the tap, level meter while the equalizer is off, a level bar in the panel, ⌘1–9 profile shortcuts: declined (2026-10-31).
- Global EQ hotkey, device "cards", tabs in the EQ window, BlackHole or any loopback hop.
