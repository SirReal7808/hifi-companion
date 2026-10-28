# HiFi Companion — start here

macOS menu-bar **system-wide PEQ**: Apple Music **SB** (sample rate + bit depth) matching, exclusive-Music lock, process-tap Pass-through to a pinned DAC, and a floating EQ with graph sweep. It is **not** a music player.

You have this clone and GitHub. That is the whole brief. Do not look for a Cursor Project store, chat transcript, or AgentStores folder.

## Current line (`main`; do not start from tag `v0.2`)

**`main`** is the live line and has this onboarding pack (`AGENTS.md`, `docs/`). Branch from `main` for new work and open a PR back to `main`. (Until 2026-10-28 the live line was `cursor/eq-fit-laptop-970c`; `main` was fast-forwarded to it and PRs #1/#2 merged. The old `cursor/*` branches are history only.)

Tag **`v0.2`** (`a49ad4b`) is the **app** snapshot only (compact footer / `eq-footer-compact-v4` / ver 19). It does **not** contain `AGENTS.md` or `docs/`. Checking it out drops this pack.

| | |
|---|---|
| **Work from** | `main` |
| **App tag** | `v0.2` at `a49ad4b` — binary rollback only; no onboarding docs |
| **Stamp / ver** | `eq-footer-compact-v4` / **0.2.0 (19)** (`MARKETING_VERSION` / `CURRENT_PROJECT_VERSION`) |
| **Install** | `~/Applications/HiFiCompanion.app` (archive: `~/Applications/HiFiCompanion-0.2.app`) |

```bash
git checkout main
git pull --ff-only
```

## Read next (in order)

1. [docs/HANDOFF.md](docs/HANDOFF.md) — product, architecture, files, operator rules
2. [docs/eq-window-decisions.md](docs/eq-window-decisions.md) — locked EQ interaction
3. [docs/eq-visual-target.md](docs/eq-visual-target.md) — visual contract + reference shots
4. [docs/audio-path.md](docs/audio-path.md) — tap → aggregate → PEQ → sweep
5. [docs/pitfalls.md](docs/pitfalls.md) — regressions we already paid for
6. [docs/preferences.md](docs/preferences.md) — how to work with Mert
7. Revert: [docs/eq-v0.2-revert.md](docs/eq-v0.2-revert.md), [docs/eq-v0.1-revert.md](docs/eq-v0.1-revert.md)
8. Cursor rule (if you use Cursor): [`.cursor/rules/eq-compact-footer.mdc`](.cursor/rules/eq-compact-footer.mdc)

## Build / run / install

Mert’s Mac is **macOS 27**. Needs Xcode, unsandboxed (`log stream` + process tap). Bundle id `com.hificompanion.app`.

```bash
xcodegen generate   # after any project.yml change (safe: project.yml is the source of truth)
xcodebuild -scheme "HiFi Companion" -configuration Release -derivedDataPath build
pkill -x HiFiCompanion 2>/dev/null || true
mkdir -p ~/Applications
rm -rf ~/Applications/HiFiCompanion.app
ditto "build/Build/Products/Release/HiFiCompanion.app" ~/Applications/HiFiCompanion.app
open ~/Applications/HiFiCompanion.app
```

Always ditto into **`~/Applications/HiFiCompanion.app`** so System Audio Recording TCC matches the binary. Launch prints `stamp=eq-footer-compact-v4 ver=19 exe=…/Applications/HiFiCompanion.app/…`. If the stamp is missing, Mert is running a stale copy.

**Versions:** bump `MARKETING_VERSION` / `CURRENT_PROJECT_VERSION` in `project.yml`, then `xcodegen generate`. `Info.plist` reads both via `$(…)`. Never hand-edit `project.pbxproj` — regenerate it. Tests are hosted in the app (`@testable import`); keep the test target's `TEST_HOST` / dependency in `project.yml`.

Unit tests: `xcodebuild -scheme "HiFi Companion" -derivedDataPath build test`.

Debug open-EQ (Mac UI tests): `--show-eq`, `--eq-unlock-controls`, `--eq-enable-pt`. Smokes: `--smoke-passthrough`, `--smoke-rate-eq`, `--smoke-sweep`.

## Do not break

- **Compact footer** — no dark footer strip; Add Band / Reset on the window background; equal pad above/below; **never clip** the right glass corners or drop shadow (`.clipped()`, overlay, ExactHeight squeeze). Shot: [docs/media/eq-footer-compact.jpg](docs/media/eq-footer-compact.jpg).
- **Process tap only** — no BlackHole hop, no switching the system default output, no Microphone prompt.
- **Exclusive Music lock** — switch SB only while Music is the sole audible client on the DAC.
- **Sweep engine** — never leave the on-demand DAC `AVAudioEngine` running idle (silences Pass-through Music).
- **Exact height** — width 900; `min == max` H(N); no green zoom; no PreferenceKey layout loop.
- **Signed zero** — exact 0 dB prints `0.0`, never `+0.0` / `-0.0`.
- **Listening tests** — Mert plays music himself. Do not start Music or YouTube for those.
- **Language** — Talk with Mert in **Turkish** (English technical terms are fine). Everything in the app and repo stays **English**: UI strings, code, comments, commit messages, docs. Write **SB** in caps.
- **Scope** — PEQ + SB match + sweep. Not a player. Android is later. Do not share the Mac audio driver.

If Mert says “0.2 sürümüne geri dönelim”, restore the **app** from tag `v0.2` / `~/Applications/HiFiCompanion-0.2.app` (see [docs/eq-v0.2-revert.md](docs/eq-v0.2-revert.md)), then return to `main` for docs. Same pattern for `v0.1` (pre–side-panel UX).
