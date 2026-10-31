# HiFi Companion — start here

Onboarding for AI agents and contributors. macOS menu-bar **system-wide PEQ** on a Core Audio process tap, Apple Music **SB** (sample rate + bit depth) matching with an exclusive-Music lock, and a graph sine sweep. It is **not** a music player.

This clone plus GitHub is the whole brief. There is no chat transcript or external project store to look for.

## Current state

| | |
|---|---|
| **Live line** | `main` — branch from it, PR back to it |
| **Latest release** | **0.4.0 (29)**, tag `v0.4.0` → `d4e788d` ([releases](docs/releases.md)) |
| **In development** | **0.4.1 (35)** — bit-exact flat path, null test, dropout log |
| **Launch stamp** | `eq-liquid-glass-v1` |
| **Installed app** | `~/Applications/HiFiCompanion.app` |
| **Archived builds** | `~/Library/Application Support/HiFiCompanion/Archives/HiFiCompanion-0.4.0.app.zip`, `…-0.3.0.app.zip`, `…-0.2.app.zip`, `…-0.1.app.zip` (zipped so Spotlight shows one app) |
| **Build output** | `build.noindex/` (the `.noindex` suffix keeps Spotlight from listing build copies) |
| **Repo** | https://github.com/SirReal7808/hifi-companion (private; `gh` signed in) |

## Working with Mert

Full rules: [docs/working-agreement.md](docs/working-agreement.md). The essentials:

- Chat with Mert in **Turkish** (English terms are fine). App and repo — UI strings, code, comments, commits, docs — stay **English**.
- Merge a PR only after Mert approves it. Never force-push or rewind `main`; never delete tags.
- Build, install, and launch yourself instead of asking Mert to.
- Listening tests are Mert's. **Never start Music or YouTube.**
- "0.2 sürümüne geri dönelim" / "0.1 …" → [docs/releases.md#rollback](docs/releases.md#rollback).

## Build, test, install

Needs Xcode and XcodeGen (`brew install xcodegen`). Unsandboxed (`log stream` + process tap); bundle id `com.hificompanion.app`.

```bash
xcodegen generate   # after any project.yml change
xcodebuild -scheme "HiFi Companion" -configuration Release -derivedDataPath build.noindex
xcodebuild -scheme "HiFi Companion" -derivedDataPath build.noindex test
pkill -x HiFiCompanion 2>/dev/null || true
mkdir -p ~/Applications
rm -rf ~/Applications/HiFiCompanion.app
ditto "build.noindex/Build/Products/Release/HiFiCompanion.app" ~/Applications/HiFiCompanion.app
open ~/Applications/HiFiCompanion.app
```

- Always install to **`~/Applications/HiFiCompanion.app`** so System Audio Recording permission matches the binary. Launch prints `HiFiCompanion launch stamp=eq-liquid-glass-v1 ver=<build> exe=…` (`ver` = `CURRENT_PROJECT_VERSION`, currently 35). A missing or old stamp means a stale copy is running.
- `project.yml` is the source of truth; never hand-edit `project.pbxproj`. Versions: `MARKETING_VERSION` / `CURRENT_PROJECT_VERSION` in `project.yml` ([bumping](docs/releases.md#bumping-the-version)).
- **Run the unit tests locally before every PR** and state the result in the PR. GitHub Actions (`.github/workflows/tests.yml`) is manual-only — do not wait on it.
- Tests are hosted in the app (`@testable import`); keep the test target's `TEST_HOST` / dependency in `project.yml`.
- Automation flags (`--show-eq`, `--eq-screenshot`, `--smoke-*`, …): [docs/architecture.md#automation-flags](docs/architecture.md#automation-flags).

## Do not break

- **Compact footer (locked)** — no footer strip; Add Band / Reset on the window background; equal pad above and below; **never clip** the side glass corners or shadow. `testCompactFooterInvariant` stays green. [Spec](docs/eq-window.md#compact-footer--locked-2026-10-27).
- **Exact height** — width 790, `min == max` H(N), no zoom, no PreferenceKey layout loop.
- **Process tap only** — no BlackHole / loopback hop, no Microphone prompt. Change the macOS output only to the user's preferred hardware device ([redesign](docs/redesign-0.3.md#output)).
- **Exclusive Music lock** — switch SB only while Music is the sole audible client on the DAC.
- **Sweep engine** — never leave the on-demand DAC `AVAudioEngine` running idle (it silences Pass-through Music).
- **Realtime** — no heap allocation in the IOProc (`PeakingBiquad.processInterleaved`, reused scratch buffers).
- **Signed zero** — exact 0 dB prints `0.0`, never `+0.0` / `-0.0` (`EQFormat.gainDB`).
- **Scope** — PEQ (the core) + SB match (independent toggle) + sweep. Not a player. macOS for now. Pass-through / lock are temporary designs; Auto EQ and other platforms wait for Mert ([vision](docs/product.md#vision-mert-2026-10-28)).

Why each rule exists: [docs/pitfalls.md](docs/pitfalls.md).

## Docs

| Doc | Read it for |
|---|---|
| [docs/product.md](docs/product.md) | What the app is and is not, shipped features, roadmap, known gaps |
| [docs/architecture.md](docs/architecture.md) | Process model, source map, persistence, automation flags, tests |
| [docs/audio-path.md](docs/audio-path.md) | SB matching, lock, process tap, PEQ, sweep, permission, troubleshooting |
| [docs/eq-window.md](docs/eq-window.md) | EQ window spec, locked footer, chrome, visual target |
| [docs/pitfalls.md](docs/pitfalls.md) | Regressions already paid for, and the fixes to keep |
| [docs/working-agreement.md](docs/working-agreement.md) | Language, git workflow, machine, listening tests, policies |
| [docs/releases.md](docs/releases.md) | Versions, tags, archives, rollback, version bumps |
| [docs/redesign-0.3.md](docs/redesign-0.3.md) | **Agreed next design:** output follow / preferred device, Parametric Equalizer switch, signal path, menu panel, phases R1–R5 |

Read `product` → `architecture` → `audio-path` → `eq-window` → `pitfalls` before changing audio or EQ code. Cursor users: [`.cursor/rules/eq-compact-footer.mdc`](.cursor/rules/eq-compact-footer.mdc) applies the footer rule automatically.
