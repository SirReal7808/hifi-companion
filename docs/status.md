# Status and backlog

Where the project stands and what comes next. Every session reads this first and the `/handoff` skill updates it last, so the next session starts without the chat history. Keep it short and current: finished work moves to [releases.md](releases.md), decisions to the topic docs.

_Last updated: 2026-11-14 (0.5.0 in progress: steps 1–4 and 5a done; build 46 = mid-track streaming-variant fix, PR #52; next is 5b media)._

## Now

- **Released:** 0.4.2 (build 41), tag `v0.4.2` → `d07f4f0`, 2026-11-13. If `gh pr merge` returns 502 (happened on #37, #39), check `origin/main` before retrying.
- **In development:** 0.5.0 public release (plan below). Steps 1–4 done; **build 45** (Developer ID + Sparkle from build 44, plus no `get-task-allow` so notarization accepts it) merged as PR #50 → `8251fcc` . Same Developer ID as 44, so no new System Audio Recording prompt is expected (not yet confirmed by Mert). **Build 46** merged as PR #52 → `fe9a815` and installed: no DAC reclock when Apple Music drops the playing track to a lower streaming variant (log 2026-11-14 13:18; [pitfall](pitfalls.md#streaming-bandwidth-dip-reclocked-the-dac-mid-track)). Not listening-tested (a bandwidth dip can't be triggered on demand); Mert will report if a mid-track 96 → 48 switch happens again — then read `audio-events.log` for a `Held … until the next track` line. Next app change bumps to build 47.
- **Audio log:** off by default since build 42; **on on Mert's Mac** (`defaults write com.hificompanion.app saveAudioLog -bool true`). If `audio-events.log` stops growing, check that setting first.
- **Reminder for Mert:** back up the Developer ID identity as `.p12` and the Sparkle EdDSA key (Backlog). He asked to be reminded.
- Branches: `main`, `spike/r4b-audibility-probe` (kept).

## Next up

**0.5.0 — public release** (planned with Mert 2026-11-13). Goal: a public GitHub repo as a **portfolio piece**, plus a signed app people can download. Not the Mac App Store. Mert is already in the Apple Developer Program. Run the steps in order; 1, 2 and 5 can go while the icon is being made.

Steps 1–4 and 5a are done; the next session takes 5b (media + doc-trim decision), then step 6.

1. ~~**Developer ID Application certificate.**~~ Done 2026-11-13: `Developer ID Application: Mert Lafci (3R38CGHB29)` in the login keychain, expires 2027-12-13; details and the renewal route in [releases.md](releases.md#signing-identity). Developer ID signing also keeps the System Audio Recording permission across updates (ad-hoc builds lose it).
2. ~~**App changes.**~~ Done 2026-11-13, build 42, PR #44: Settings → Apps hidden, Save audio log toggle (default off), deployment target 14.2.
3. ~~**Icon.**~~ Done 2026-11-13, build 43, PR #46: `HiFiCompanion/AppIcon.icon` (Icon Composer) with one full-bleed layer, `Assets/artwork.png` = Gemini (`agy`) concept B cropped to its tile. Mert: fine for now, a more professional logo later replaces it (start over then); same icon in light and dark is OK. Drafts: `~/Library/Application Support/HiFiCompanion/IconDrafts/`. Lesson: give `agy` the app's screenshots as reference, unreferenced drafts come out generic. The menu bar template icon (replacing the "HiFi Companion" title placeholder) is optional, in Backlog.
4. **Distribution**, split in two:
   - ~~**4a**~~ Done 2026-11-13, build 44, PR #48: Release builds signed with Developer ID (Sparkle helpers re-signed by `scripts/sign-sparkle-helpers.sh`), Sparkle 2 with feed URL + EdDSA public key, Settings → General → Updates. Details in [releases.md](releases.md#updates-sparkle).
   - ~~**4b**~~ Done 2026-11-13 (build 45, PR #50): `scripts/package-release.sh` notarizes and staples the app, builds a signed, notarized `.dmg` and updates `appcast.xml` in `~/Library/Application Support/HiFiCompanion/Releases/`; `/release` uploads both to the GitHub Release. Keychain profile `HiFiCompanion-notary` created by Mert. Details in [releases.md](releases.md#packaging-a-release). Verified end to end into a scratch folder (app and dmg Accepted, stapled, Gatekeeper `Notarized Developer ID`); nothing published yet. The first submission waited ~35 min in Apple's queue, later ones took minutes. The feed only works after step 6 (public repo).
5. **Repo prep**, split in two:
   - ~~**5a**~~ Done 2026-11-14 (docs only, no build bump): `LICENSE` (MIT, © 2026 Mert Lafcı), README rewritten as a showcase (badges, Download section, "How it works", "Built with AI agents"), `tests.yml` now runs on pull requests and pushes to `main` but only once the repo is public (`if: … private == false`; manual runs always work), so the badge goes green by itself after step 6.
   - **5b:** demo GIF of sweep → FIX PEAK, a light-mode EQ screenshot (Backlog: none exists), and Mert's call on **trimming personal docs**. Recommendation: do not trim `status.md` / `working-agreement.md`; the `/task` and `/handoff` loop reads them every session and they are the showcase of the AI workflow. Instead scan them in step 6 for anything private. Mert decides.
6. **Go public:** scan git history, PR descriptions and comments (they all become public), then flip the repo to public — outward-facing, ask Mert at that moment.

Mert's call on risks: testing on other Macs / DACs / macOS 14–15 is not a blocker; users will write to him and he uses the app daily.

## Backlog (not scheduled)

Small, Mert has not asked for them; propose before starting.

- **Back up the Developer ID identity (Mert, remind him).** The private key exists only in this Mac's login keychain. Mert exports it himself: Keychain Access → the `Developer ID Application: Mert Lafci` certificate → Export → `.p12` with his own password, stored somewhere safe. Not a blocker (a new certificate can be issued). Mert asked to be reminded (2026-11-13). Also back up the **Sparkle EdDSA private key** (`generate_keys -x <file>`, see [releases.md](releases.md#updates-sparkle)); unlike the certificate it cannot be replaced once a public build ships.
- **Null test at other rates.** Bit-exactness was measured at 44.1 kHz only (DX5 II). Run `scripts/null-test.sh` with the DAC at 96 kHz (and 48 kHz) when nobody is listening. Measurement only.
- **Format lines from other apps.** `LogStreamReader` takes `AudioQueue` lines from any process in `com.apple.coreaudio`; a bogus 48 kHz line (likely another app) was held as Music's next track on 2026-10-31 21:20. Harmless since build 36 (AppleScript decides at the track change), but filtering `AudioQueue` lines to Music would remove the noise. Needs `audio-path-reviewer`.
- **Settings → Apps tab (hidden since build 42).** The exclusion list and its page are kept in code (`SettingsTab.apps`, `EqualizerExclusions`); re-show it only if the tap ever honors the list (wiring it in stays declined, see below).
- **Code-review leftovers (2026-10-28, low):** `PEQView.swift` is 2,000 lines (split by component, no visual change); `isPassThroughFailure` classifies errors by text; logging mixes `print` and `os.Logger`; test target both hosted and compiling app sources.
- **Docs media:** no light-mode EQ screenshot.
- **Menu bar template icon (optional, from 0.5.0 step 3).** A monochrome SVG template image in front of the menu bar title, replacing the "HiFi Companion" text placeholder (`MenuBarTitle.placeholder`). Best done together with the future professional logo.

## Later (Mert decides when)

- AutoEQ `ParametricEQ.txt` import / export; Auto EQ (Mert holds the details).
- Windows / Android (maybe never).
- Bundled virtual device so capture needs no System Audio Recording prompt.

## Decided — do not re-propose

- App icon: no hand-built vector redraw of the Gemini artwork; Mert preferred Gemini's concept B as is (2026-11-13). A new logo comes later as its own project.

- Pausing / resuming Music around a rate switch: no. The ~1 s gap at the start of a track with a new rate is normal (2026-11-01).
- Audible-only exclusive lock: dropped; the ~10 s browser delay is accepted (README → Known behavior).
- Wiring the Apps exclusion list into the tap, level meter while the equalizer is off, a level bar in the panel, ⌘1–9 profile shortcuts: declined (2026-10-31).
- Global EQ hotkey, device "cards", tabs in the EQ window, BlackHole or any loopback hop.
