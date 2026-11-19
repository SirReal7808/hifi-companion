# Status and backlog

Where the project stands and what comes next. Every session reads this first and the `/handoff` skill updates it last, so the next session starts without the chat history. Keep it short and current: finished work moves to [releases.md](releases.md), decisions to the topic docs.

_Last updated: 2026-11-19 (0.5.0 released, first public download; nothing scheduled)._

## Now

- **Released:** 0.5.0 (build 50), tag `v0.5.0` → `51fa885`, 2026-11-19. [GitHub Release](https://github.com/SirReal7808/hifi-companion/releases/tag/v0.5.0) with the notarized `HiFiCompanion-0.5.0.dmg` and `appcast.xml`; `releases/latest/download/appcast.xml` and the dmg return 200, the downloaded dmg passes Gatekeeper (`Notarized Developer ID`). Build 50 is build 49's code with the version set to 0.5.0 (PR #65). Keep `~/Library/Application Support/HiFiCompanion/Releases/`: it holds every shipped dmg and the appcast history.
- **Next release:** the next app change bumps to 0.5.1 (build 51) and ships with `/release` the same way; Sparkle offers it to 0.5.0 users. If `gh pr merge` returns 502 (happened on #37, #39), check `origin/main` before retrying.
- **Watching:** build 46's mid-track streaming-variant hold (Mert reports a mid-track 96 → 48 switch → read `audio-events.log` for `Held … until the next track`); build 48's EQ window fix (Backlog).
- **Audio log:** off by default since build 42; **on on Mert's Mac** (`defaults write com.hificompanion.app saveAudioLog -bool true`). If `audio-events.log` stops growing, check that setting first.
- **Key backup done 2026-11-19:** the Developer ID identity and the Sparkle EdDSA private key have offline backups (locations kept out of the repo). Restore commands in [releases.md](releases.md#updates-sparkle).
- Branches: `main`, `spike/r4b-audibility-probe` (kept).

## Next up

Nothing scheduled. 0.5.0 (public release, planned 2026-11-13) is done; its plan's details live in [releases.md](releases.md) (signing, Sparkle, packaging). Pick from the Backlog with Mert, or wait for user reports. Mert's call on risks: testing on other Macs / DACs / macOS 14–15 is not a blocker; users will write to him and he uses the app daily.

## Backlog (not scheduled)

Small, Mert has not asked for them; propose before starting.

- **Filter curve changes with the sample rate (evaluate in detail later, Mert 2026-11-15).** The RBJ biquads are designed at the live rate, so the curve near the top octave differs per track rate (SB match changes it every track). Mert's "Bunny" preset: 9 kHz peak 4.55 dB at 44.1 kHz, 4.33 at 48 kHz, 3.36 at 96 kHz; Auto Gain follows (−4.6 vs the CrinGraph site's −4.3, which computes at a fixed 48 kHz). Options: analog-matched coefficients (Vicanek / Orfanidis; rate-independent, but diverges from shared PEQs that assume RBJ at 44.1/48 kHz, e.g. AutoEQ, Equalizer APO, hardware DSPs), or reproducing the RBJ-at-48 kHz curve at every rate (inexact at 44.1 kHz near Nyquist). Current recommendation: stay on RBJ until after the public release. Needs `audio-path-reviewer`.
- **EQ window vanishing (fixed in build 48, PR #57; watching).** Cause found 2026-11-15 15:22: the all-Spaces window was dropped from every Space by the WindowServer when the profile menu opened, while AppKit still thought it visible ([pitfall](pitfalls.md#eq-window-lost-from-every-space)). Build 48 drops `.canJoinAllSpaces` and re-fronts a lost window on ⌘Tab / Dock. If it vanishes again, look for `EQ lost by WindowServer` in `log show --predicate 'subsystem == "HiFiCompanion"'`; remove the window-event diagnostics after a quiet week.
- **Null test at other rates.** Bit-exactness was measured at 44.1 kHz only (DX5 II). Run `scripts/null-test.sh` with the DAC at 96 kHz (and 48 kHz) when nobody is listening. Measurement only.
- **Format lines from other apps.** `LogStreamReader` takes `AudioQueue` lines from any process in `com.apple.coreaudio`; a bogus 48 kHz line (likely another app) was held as Music's next track on 2026-10-31 21:20. Harmless since build 36 (AppleScript decides at the track change), but filtering `AudioQueue` lines to Music would remove the noise. Needs `audio-path-reviewer`.
- **Settings → Apps tab (hidden since build 42).** The exclusion list and its page are kept in code (`SettingsTab.apps`, `EqualizerExclusions`); re-show it only if the tap ever honors the list (wiring it in stays declined, see below).
- **Code-review leftovers (2026-10-28, low):** `PEQView.swift` is 2,000 lines (split by component, no visual change); `isPassThroughFailure` classifies errors by text; logging mixes `print` and `os.Logger`; test target both hosted and compiling app sources.
- **Menu bar template icon (optional, from 0.5.0 step 3).** A monochrome SVG template image in front of the menu bar title, replacing the "HiFi Companion" text placeholder (`MenuBarTitle.placeholder`). Best done together with the future professional logo.

## Later (Mert decides when)

- A professional logo replacing the 0.5.0 icon (Gemini concept B; start over, don't redraw it). Drafts: `~/Library/Application Support/HiFiCompanion/IconDrafts/`; give `agy` the app's screenshots as reference.
- AutoEQ `ParametricEQ.txt` import / export; Auto EQ (Mert holds the details).
- Windows / Android (maybe never).
- Bundled virtual device so capture needs no System Audio Recording prompt.

## Decided — do not re-propose

- App icon: no hand-built vector redraw of the Gemini artwork; Mert preferred Gemini's concept B as is (2026-11-13). A new logo comes later as its own project.

- Pausing / resuming Music around a rate switch: no. The ~1 s gap at the start of a track with a new rate is normal (2026-11-01).
- Audible-only exclusive lock: dropped; the ~10 s browser delay is accepted (README → Known behavior).
- Wiring the Apps exclusion list into the tap, level meter while the equalizer is off, a level bar in the panel, ⌘1–9 profile shortcuts: declined (2026-10-31).
- Global EQ hotkey, device "cards", tabs in the EQ window, BlackHole or any loopback hop.
