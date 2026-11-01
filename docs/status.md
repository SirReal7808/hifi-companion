# Status and backlog

Where the project stands and what comes next. Every session reads this first and the `/handoff` skill updates it last, so the next session starts without the chat history. Keep it short and current: finished work moves to [releases.md](releases.md), decisions to the topic docs.

_Last updated: 2026-11-01 (after PR #33, menu panel dismiss fix)._

## Now

- **Released:** 0.4.1 (build 36), tag `v0.4.1` → `c31580e`. Installed at `~/Applications/HiFiCompanion.app`.
- **In development:** 0.4.2 — build 37 merged (PR #33, menu panel closes after Open Equalizer… / Settings…), installed. Release with `/release` when Mert says so.
- **Open PRs:** none.
- **Waiting on Mert:** nothing. Branches: only `main` and `spike/r4b-audibility-probe` (kept for the spike code).

## Next up

Bugs Mert reported on 2026-11-01, in this order. Each is one session, one branch, one PR.

1. **Menu panel looks muddy in Light appearance** — the font is unchanged (`.system`, SF). Cause: Settings → General → Appearance is **Light** while macOS is **Dark** (checked 2026-11-01). `AppearancePreference.applyToApp()` forces Aqua on the whole app, so the panel draws dark text on a glass background tinted by the dark menu bar. Recommended fix: the menu panel always follows the system appearance, like Control Center and other menu bar extras; the Appearance setting keeps applying to the EQ and Settings windows. Check light/light, dark/dark and both mixed cases; update the Appearance help text if needed.

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
