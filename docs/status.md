# Status and backlog

Where the project stands and what comes next. Every session reads this first and the `/handoff` skill updates it last, so the next session starts without the chat history. Keep it short and current: finished work moves to [releases.md](releases.md), decisions to the topic docs.

_Last updated: 2026-11-13 (0.4.2 released, build 41; 0.5.0 in progress: step 1 Developer ID certificate done in PR #42, next is step 2 App changes)._

## Now

- **Released:** 0.4.2 (build 41 = build 40 with the version bumped), tag `v0.4.2` → `d07f4f0`, 2026-11-13. Installed at `~/Applications/HiFiCompanion.app`.
- **PR #39** (release): merged as `d07f4f0`; GitHub's merge call returned 502 again (as with #37), so the PR was closed by hand with a note. If `gh pr merge` returns 502, check `origin/main` before retrying.
- **In development:** 0.5.0 public release (plan below). Step 1 (Developer ID certificate) done, PR #42 merged as `ffd6eb7`. No app change yet; the first one bumps to build 42.
- **Reminder for Mert:** back up the Developer ID identity as `.p12` (Backlog). He asked to be reminded.
- Branches: `main`, `spike/r4b-audibility-probe` (kept).

## Next up

**0.5.0 — public release** (planned with Mert 2026-11-13). Goal: a public GitHub repo as a **portfolio piece**, plus a signed app people can download. Not the Mac App Store. Mert is already in the Apple Developer Program. Run the steps in order; 1, 2 and 5 can go while the icon is being made.

1. ~~**Developer ID Application certificate.**~~ Done 2026-11-13: `Developer ID Application: Mert Lafci (3R38CGHB29)` in the login keychain, expires 2027-12-13; details and the renewal route in [releases.md](releases.md#signing-identity). Developer ID signing also keeps the System Audio Recording permission across updates (ad-hoc builds lose it).
2. **App changes** (needs `audio-path-reviewer` for the log part):
   - Hide the Settings → **Apps** tab. Keep the saved list and its code; add a Backlog note (wiring it into the tap stays declined, see below).
   - **Stream Health file log toggle**, default **off**: Diagnostics counters (dropouts, slow cycles) always run in memory; writing `audio-events.log` follows a new "Save audio log" setting, and "Show audio log" is disabled while it is off. Reason: privacy (the log names other apps playing audio and when), not cost (it is event-based, ~10 KB over 3 days). **Turn it on on Mert's Mac** — debugging with him relies on this log.
   - `project.yml` deployment target 14.0 → 14.2.
3. **Icon.** Mert supplies it; Antigravity CLI (`agy`, installed at `~/.local/bin/agy`, model 3.8) may make drafts for him to pick from. Wanted: Icon Composer layers (1024×1024 background colour / gradient + 1–2 transparent SVG foreground layers, no baked-in shadow or glass, ~10 % margin, readable at 32 px) or one 1024×1024 PNG; plus an optional monochrome SVG **menu bar template icon** to replace the "HiFi Companion" title placeholder. Never use `agy` for screenshots or the demo GIF — those are real captures. Send it only image briefs, not repo content.
4. **Distribution:** Developer ID signing + notarization, a `.dmg` on GitHub Releases, **Sparkle** auto-update (appcast + EdDSA-signed updates from GitHub Releases, "Check for Updates…" in Settings). Wire all of it into `/release`.
5. **Repo prep:** MIT license; trim personal working docs (status, working-agreement, notes written for Mert) but keep `AGENTS.md`, `.claude/` and the reviewers as a showcase of the AI-assisted workflow; README as a showcase (demo GIF of sweep → FIX PEAK, light and dark screenshots, Download button, a "How it works" section: process tap, allocation-free realtime biquad, bit-exact null test, Apple Music SB detection); CI on PRs (free on public repos) with a tests badge.
6. **Go public:** scan git history, PR descriptions and comments (they all become public), then flip the repo to public — outward-facing, ask Mert at that moment.

Mert's call on risks: testing on other Macs / DACs / macOS 14–15 is not a blocker; users will write to him and he uses the app daily.

## Backlog (not scheduled)

Small, Mert has not asked for them; propose before starting.

- **Back up the Developer ID identity (Mert, remind him).** The private key exists only in this Mac's login keychain. Mert exports it himself: Keychain Access → the `Developer ID Application: Mert Lafci` certificate → Export → `.p12` with his own password, stored somewhere safe. Not a blocker (a new certificate can be issued). Mert asked to be reminded (2026-11-13).
- **Null test at other rates.** Bit-exactness was measured at 44.1 kHz only (DX5 II). Run `scripts/null-test.sh` with the DAC at 96 kHz (and 48 kHz) when nobody is listening. Measurement only.
- **Format lines from other apps.** `LogStreamReader` takes `AudioQueue` lines from any process in `com.apple.coreaudio`; a bogus 48 kHz line (likely another app) was held as Music's next track on 2026-10-31 21:20. Harmless since build 36 (AppleScript decides at the track change), but filtering `AudioQueue` lines to Music would remove the noise. Needs `audio-path-reviewer`.
- **Code-review leftovers (2026-10-28, low):** `PEQView.swift` is 2,000 lines (split by component, no visual change); `isPassThroughFailure` classifies errors by text; logging mixes `print` and `os.Logger`; `project.yml` deployment target 14.0 vs the 14.2 the app needs; test target both hosted and compiling app sources.
- **Docs media:** no light-mode EQ screenshot.

## Later (Mert decides when)

- AutoEQ `ParametricEQ.txt` import / export; Auto EQ (Mert holds the details).
- Windows / Android (maybe never).
- Bundled virtual device so capture needs no System Audio Recording prompt.

## Decided — do not re-propose

- Pausing / resuming Music around a rate switch: no. The ~1 s gap at the start of a track with a new rate is normal (2026-11-01).
- Audible-only exclusive lock: dropped; the ~10 s browser delay is accepted (README → Known behavior).
- Wiring the Apps exclusion list into the tap, level meter while the equalizer is off, a level bar in the panel, ⌘1–9 profile shortcuts: declined (2026-10-31).
- Global EQ hotkey, device "cards", tabs in the EQ window, BlackHole or any loopback hop.
