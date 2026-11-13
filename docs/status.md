# Status and backlog

Where the project stands and what comes next. Every session reads this first and the `/handoff` skill updates it last, so the next session starts without the chat history. Keep it short and current: finished work moves to [releases.md](releases.md), decisions to the topic docs.

_Last updated: 2026-11-13 (0.4.2 released, build 41)._

## Now

- **Released:** 0.4.2 (build 41 = build 40 with the version bumped), tag `v0.4.2` → `d07f4f0`, 2026-11-13. Installed at `~/Applications/HiFiCompanion.app`.
- **PR #39** (release): merged as `d07f4f0`; GitHub's merge call returned 502 again (as with #37), so the PR was closed by hand with a note. If `gh pr merge` returns 502, check `origin/main` before retrying.
- **In development:** nothing. The next app change bumps to 0.4.3 / build 42.
- Branches: `main`, `spike/r4b-audibility-probe` (kept).

## Next up

Nothing scheduled. Ask Mert, or propose an item from the backlog.

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
