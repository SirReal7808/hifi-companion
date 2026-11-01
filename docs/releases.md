# Releases

Version history, git tags, archived app builds, how to roll back, and how to bump the version.

## Versions

| Release | Tag → commit | Launch stamp / build | Archived app | What it is |
|---|---|---|---|---|
| **0.4.1** (current release) | `v0.4.1` → `c31580e` | `eq-liquid-glass-v1` / 36 | `Archives/HiFiCompanion-0.4.1.app.zip` | Bit-exact flat-equalizer path (tap drift compensation off), null test, dropout log, rate switches only at track changes |
| **0.4.0** | `v0.4.0` → `d4e788d` | `eq-liquid-glass-v1` / 29 | `Archives/HiFiCompanion-0.4.0.app.zip` | EQ window in native Liquid Glass styling. Includes the never-tagged 0.3.1 work |
| **0.3.0** | `v0.3.0` → `919e241` | `eq-footer-compact-v4` / 26 | `Archives/HiFiCompanion-0.3.0.app.zip` | Redesign R1–R5: follow macOS output, Parametric Equalizer switch, per-device curves, signal path, menu panel, Settings; code-review EQ fixes. Includes the never-tagged 0.2.1 work |
| **0.2** | `v0.2` → `a49ad4b` | `eq-footer-compact-v4` / 19 | `Archives/HiFiCompanion-0.2.app.zip` | Approved EQ: compact footer, laptop fit, side-panel UX |
| **0.1** | `v0.1` → `fd09485` | `window-chrome-v7` / 7 | `Archives/HiFiCompanion-0.1.app.zip` | Last working EQ **before** the side-panel UX redesign |

All tags are annotated and reachable from `main`. **Do not delete them** unless Mert retires a snapshot.

Note: the tagged builds still report `CFBundleShortVersionString` **0.1.0**. The marketing version became `0.2.0` when versioning moved to `project.yml` (2026-10-28, after the tag); the build number (19) is unchanged.

### 0.4.1 — 2026-11-01

Verified by Mert's listening tests (44.1 ↔ 96 kHz track changes, build 36).

- **Bit-exact when flat:** the tap's drift compensation is off on hardware-clocked outputs (USB, built-in, HDMI, …; still on for Bluetooth / AirPlay / aggregate / virtual). With it on, macOS resampled the tap and no sample reached the DAC unchanged (null test, DX5 II 44.1 kHz); off, the flat-equalizer path is bit-exact.
- **No mid-track reclock from the next track's preload:** Apple Music logs the next track's format ~20 s early (gapless); rate changes now wait for the track change unless AppleScript says the playing track has that rate, and every track change moves the DAC to the playing track's rate (also when no format line came).
- **No mid-track rebuilds for an unchanged DAC format:** detection sources can disagree on a track's bit depth (ALAC 16-bit vs AudioQueue 24-bit) while both land on the DAC's 24-bit container; a late second report used to stop and rebuild the tap mid-track (~0.2 s gap — found in the dropout log, 18:56:57). Now a switch that leaves the DAC as it is, with the tap already there, is accepted without touching audio.
- **Dropout log:** `~/Library/Logs/HiFiCompanion/audio-events.log` records tap start / stop / rebuilds, rate and track changes, and IOProc stream breaks (sample-time gaps, short tap buffers, macOS overloads) with millisecond times; Settings → Diagnostics → Stream Health shows the count and opens the log.
- `--null-test` / `scripts/null-test.sh`: plays a soft 24-bit test file through a flat-equalizer tap and checks the samples handed to the DAC are bit-exact (drift compensation on / off, bands at 0 dB). Measurement only; no change to normal playback.

### 0.4.0 — 2026-10-31

The EQ window redesign; 0.3.1 (builds 27–28) was never tagged on its own. Build 29 is build 28 with the version bumped.

- **EQ window, native Liquid Glass** (agreed from concept mockups with Mert, 2026-10-31): 790 pt wide; Undo / Redo in one glass capsule; graph with dB / Hz axis labels and glass handles, all gray while Bypass EQ is on; bands in one grouped container, lit from the leading edge in the band color (stronger when selected), FREQ / GAIN / Q as large values under small caps labels, larger reorder / mute / remove controls; ↑ / ↓ reorder slides the rows; side glass: OUTPUT stack beside Auto Gain / Bypass EQ (orange when on) / Gain Match, SWEEP section with LEVEL and FIX PEAK / FIX DIP lit from the edge; clipping warning as a glass pill with a Fix button; sweep needle line breaks around its (larger) label and is 2 pt while held; the dark strip under Add Band / Reset is gone (chips framed to the 30 pt the height math expects).

### 0.3.0 — 2026-10-31

Everything planned in [redesign-0.3.md](redesign-0.3.md) (R1–R5) plus the 0.2.1 code-review fixes below; 0.2.1 was never tagged on its own. Build 26 is build 25 with the version bumped.

- **Build 25 (R5):** the menu bar opens a panel (output + Sample Rate / Bit Depth header, signal path line with colored dot, Parametric Equalizer and Apple Music Mode switches, Profile, Output, Open Equalizer… ⌘E, Settings… ⌘,); a gray **Paused** next to Apple Music Mode while other apps play; optional menu bar title items (Device · Sample Rate / Bit Depth · Profile); Settings window with General (launch at login, title items, appearance), Output (preferred device, saved per-device curves), Apps (exclusion list — saved, not yet applied to the tap) and Diagnostics (signal path, input level meter, equalizer headroom, device formats / buffer / latency, Apple Music state); first-run explainer before the System Audio Recording prompt; Bluetooth outputs show **Bluetooth (lossy)** instead of Direct; test tone button removed.

### 0.2 — 2026-10-27

On top of 0.1:

- Side-panel UX: glass knobs on OUTPUT GAIN and GAIN LEVEL, ALL CAPS labels, FIX PEAK / FIX DIP, no steppers, framed OUTPUT GAIN like GAIN LEVEL, hairline above TONE GENERATOR, soft knob scroll with inverted trackpad, SF Pro.
- Laptop fit: H(N) clamps to `visibleFrame − 16`; graph shrinks first; middle hugs `max(band list, measured side)`.
- **Compact footer (locked):** no footer strip; Add Band / Reset on the window background; equal pad above / below; side glass corners and shadow unclipped.

### 0.1 — 2026-10-27

Menu-bar SB matching with exclusive-Music lock, process-tap Pass-through, 10-band PK / LS / HS PEQ, response graph + sweep + Peak / Dip, frosted-glass EQ window with exact height and no zoom, profiles, undo / redo, Auto output gain, Bypass + Gain Match. Window chrome: normal `NSWindow`, standard close button.

### 0.2.1 — folded into 0.3.0 (builds 20–24, never tagged)

EQ-focused fixes from the 2026-10-28 code review (no visual changes):

- Clicking a graph handle only selects it; drags move relative to where the press started (a click used to nudge the band up to ~1 dB / ~7 %).
- OUTPUT GAIN / GAIN LEVEL knob drags and scroll ticks are one undo step per continuous run (each 0.1 dB tick used to be its own step).
- OUTPUT GAIN knob drag is 0.1 dB per point (was ~1.4 dB per point).
- Band Q floor is 0.1 (what the DSP applies); frequencies near whole kHz keep their decimals (1.96 kHz no longer shows as 2 kHz).
- Apple Music detection: the AppleScript fallback runs only until `log stream` produces a format and only while Music is running, on the main thread; `log stream` lines split across reads are reassembled, and `log` restarts with backoff if it exits.
- Unit tests no longer start the app's services (the hosted test app used to run `log stream` and SB matching against the real DAC).
- Dead code removed; the DSP (`PeakingBiquad`) no longer depends on AVFoundation.
- **Build 21 (R1 + R2a):** EQ document extracted (`PEQDocument`). The equalizer follows the macOS output; a picked device becomes the preferred output (selected at launch / pick / plug-in, never forced back); unplug, replug and wake re-attach automatically; exclusive players suspend the equalizer; "Pass-through" is now the persisted **Parametric Equalizer** switch; "PEQ…" is "Open Equalizer… ⌘E"; System Default works with the equalizer.
- **Build 22 (R2b):** events replace the 0.4 s poll (5 s safety net; Signal meter only while the equalizer runs), so the idle app wakes ~12× less; no main-thread waits on the audio queue; sweep press no longer waits on the DAC wake engine.
- **Build 23 (R3):** per-device EQ curves (each output remembers its own; new devices start flat; the existing curve moves to the first device); saved curves and profiles tolerate missing fields; an unreadable profile file is backed up, never overwritten.
- **Build 24 (R4a + fixes):** Apple Music Mode switch; signal path line in the menu (Direct / Parametric Equalizer / Resampled / Mixed); no "Locked" wording; EQ window re-measures on reopen (footer chips no longer clipped); Spotlight shows one app.

### Docs and repo since 0.2

- 2026-10-28: onboarding docs pack, `CLAUDE.md`, versioning moved to `project.yml` (0.2.0 / 19), `main` fast-forwarded to the former live branch `cursor/eq-fit-laptop-970c` (PRs #1–#4 merged), old `cursor/*` branches deleted, docs reorganized.

## Rollback

Trigger phrases: "<version> sürümüne geri dönelim" — e.g. "0.4.0 sürümüne geri dönelim", "0.2 …". Every release in the table above has an archive and a tag.

The `v0.1` / `v0.2` tags contain the **app** only — the docs (`AGENTS.md`, `docs/`) were added after them. Prefer the archived binary; if you check out a tag, return to `main` for the docs afterwards.

Archives live zipped in `~/Library/Application Support/HiFiCompanion/Archives/` (since 2026-10-31), so Spotlight lists only the installed app.

**Run an archived build (no git change):**

```bash
pkill -x HiFiCompanion 2>/dev/null || true
rm -rf /tmp/hifi-rollback
ditto -x -k ~/Library/Application\ Support/HiFiCompanion/Archives/HiFiCompanion-0.2.app.zip /tmp/hifi-rollback   # or -0.4.1, -0.4.0, -0.3.0, -0.1
open /tmp/hifi-rollback/*.app
```

Running from `/tmp` is a different path, so macOS may ask for System Audio Recording again; for real use, install it instead:

**Make an archive the installed app:**

```bash
pkill -x HiFiCompanion 2>/dev/null || true
rm -rf /tmp/hifi-rollback ~/Applications/HiFiCompanion.app
ditto -x -k ~/Library/Application\ Support/HiFiCompanion/Archives/HiFiCompanion-0.2.app.zip /tmp/hifi-rollback
ditto /tmp/hifi-rollback/*.app ~/Applications/HiFiCompanion.app
open ~/Applications/HiFiCompanion.app
```

**Inspect or rebuild the tagged sources:**

```bash
git fetch origin --tags
git checkout v0.2            # detached HEAD; rebuild + install per AGENTS.md if needed
git checkout main            # back to the live line (and the docs)
```

**Bring the code of a release back onto `main`:** do it on a branch and PR it like any other change — for example `git checkout -b revert-to-v0.2 main && git checkout v0.2 -- HiFiCompanion HiFiCompanionTests project.yml && xcodegen generate`, then build, test, and open a PR. Never `reset --hard` or force-push `main`.

## Bumping the version

**Scheme (Mert, 2026-10-28):** `0.MINOR.PATCH`. Every release bumps the third number (0.2.1, 0.2.2, …). An important change bumps the middle number and resets the third (0.3.0) — Mert decides when. The build number (`CURRENT_PROJECT_VERSION`) goes up by 1 for every build Mert installs, independent of the version.

1. Edit `project.yml`: `MARKETING_VERSION` (user-facing, e.g. `0.3.0`) and `CURRENT_PROJECT_VERSION` (build number, increment by 1 for every build Mert installs).
2. `xcodegen generate`. `Info.plist` picks both up via `$(MARKETING_VERSION)` / `$(CURRENT_PROJECT_VERSION)`. Never hand-edit `project.pbxproj`.
3. When the EQ window changes visibly, also change `PEQPanelController.buildStamp` so the launch log proves which binary runs.
4. Build, test, install, and check the launch log `stamp=` / `ver=`.

## Cutting a release

When Mert approves a build as a release:

1. Make sure it is merged on `main`.
2. Tag it: `git tag -a v0.N -m "HiFi Companion 0.N — <summary>" && git push origin v0.N`.
3. Archive the installed build as a zip (never as a second `.app`, which Spotlight would list): `ditto -c -k --keepParent ~/Applications/HiFiCompanion.app ~/Library/Application\ Support/HiFiCompanion/Archives/HiFiCompanion-0.N.app.zip`.
4. Add a row and a section to this file.
