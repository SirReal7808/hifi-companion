# Status and backlog

Where the project stands and what comes next. A new session reads this first, and it is updated whenever the state changes (not at the end of every session), so a cold start needs no chat history. Keep it short and current: finished work moves to [releases.md](releases.md), decisions to the topic docs.

_Last updated: 2026-11-23 (0.5.1 in PR #68; the curve still differs audibly at 96 kHz — Next up)._

## Now

- **Released:** 0.5.0 (build 50), tag `v0.5.0` → `51fa885`, 2026-11-19. [GitHub Release](https://github.com/SirReal7808/hifi-companion/releases/tag/v0.5.0) with the notarized `HiFiCompanion-0.5.0.dmg` and `appcast.xml`; `releases/latest/download/appcast.xml` and the dmg return 200, the downloaded dmg passes Gatekeeper (`Notarized Developer ID`). Build 50 is build 49's code with the version set to 0.5.0 (PR #65). Keep `~/Library/Application Support/HiFiCompanion/Releases/`: it holds every shipped dmg and the appcast history.
- **In development:** 0.5.1 (build 51) on `fix/eq-three-bugs`, [PR #68](https://github.com/SirReal7808/hifi-companion/pull/68) open, **installed** in `~/Applications`, not merged. Mert tested OK: Auto Gain stable across rates, dropped window stays put, FIX PEAK no longer overwrites a hand band, Apple Music no longer jumps in front after a Space swipe. **Not OK yet:** the curve at 96 kHz (Next up). Finish that on the same branch / PR, then Mert's OK → merge → `/release`.
- **Next release:** 0.5.1 ships with `/release` the same way; Sparkle offers it to 0.5.0 users. If `gh pr merge` returns 502 (happened on #37, #39), check `origin/main` before retrying.
- **Watching:** build 46's mid-track streaming-variant hold (Mert reports a mid-track 96 → 48 switch → read `audio-events.log` for `Held … until the next track`); build 48's EQ window fix (Backlog).
- **Audio log:** off by default since build 42; **on on Mert's Mac** (`defaults write com.hificompanion.app saveAudioLog -bool true`). If `audio-events.log` stops growing, check that setting first.
- **Key backup done 2026-11-19:** the Developer ID identity and the Sparkle EdDSA private key have offline backups (locations kept out of the repo). Restore commands in [releases.md](releases.md#updates-sparkle).
- Branches: `main`, `spike/r4b-audibility-probe` (kept).

## Next up

1. **EQ still sounds different at 96 kHz (Mert 2026-11-23 19:09, audible; most important).** Same "Bunny" curve, tuned by ear at 44.1 kHz; PR #68's `ReferenceRateDesign` cut the 96 kHz difference from 2.2 dB to ≈ 0.6 dB, still audible. Current Bunny: LS 140 −2.7 Q0.5 · PK 570 +1.6 Q0.6 · 1.7k −1.9 Q1.3 · 3.1k +3.3 Q1.7 · 7.1k −7 Q1.1 · 9.3k +9.2 Q2 · 12k −14 Q4.5. Residual at 96 vs 44.1 kHz (offline model of the shipped math): +0.4…+0.58 dB at 8–9 kHz (the rising flank of the 9.3 kHz +9.2 dB peak, 96 kHz louder), −0.2…−0.35 dB at 13–18 kHz. Cause: a 44.1 kHz RBJ peak is asymmetric (upper flank squeezed toward 22.05 kHz); an RBJ peak at 96 kHz is near-symmetric, so matching only centre / Q (`ReferenceRateDesign.peakingMatch`) cannot follow both flanks.
   - Recommended next: drop the RBJ-shape constraint at high rates — fit a **general biquad (5 free coefficients) per band** to the band's 44.1 kHz magnitude (least squares on dB, 20 Hz–20 kHz; seed with the current closed-form result; keep stability: poles inside the unit circle, min-phase zeros). Offline, a joint fit of all bands with RBJ shapes already reached 0.29 dB; a free biquad per band should go well below 0.1 dB. Run the fit off the main thread / outside the processor lock (it is heavier); cache per (band, rate).
   - Done when: Bunny (and the edge cases in `ReferenceRateDesignTests`) stay within ~0.1 dB of the 44.1 kHz curve at 48 / 88.2 / 96 / 192 kHz up to 20 kHz, tests prove it, `audio-path-reviewer` is clean, and Mert hears no difference between a 44.1 and a 96 kHz track.
   - Prototype scripts were in the session scratchpad (gone); the math is in `ReferenceRateDesign.swift` and its tests.

## Backlog (not scheduled)

Small, Mert has not asked for them; propose before starting.

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
