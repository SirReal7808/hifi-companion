# HiFi Companion — start here

macOS menu-bar **system-wide PEQ**: Apple Music **SB** (sample rate + bit depth) matching, exclusive-Music lock, process-tap Pass-through to a pinned DAC, and a floating EQ with graph sweep. It is **not** a music player.

You have this clone and GitHub. That is the whole brief. Do not look for a Cursor Project store, chat transcript, or AgentStores folder.

## Current snapshot (do not start from `main`)

| | |
|---|---|
| **Tag** | `v0.2` |
| **Commit** | `a49ad4b` |
| **Live branch** | `cursor/eq-fit-laptop-970c` |
| **Stamp / ver** | `eq-footer-compact-v4` / CFBundleVersion **19** |
| **Install** | `~/Applications/HiFiCompanion.app` (archive: `~/Applications/HiFiCompanion-0.2.app`) |

`main` (`d648f22`) predates the EQ window. Open PRs: [#1](https://github.com/SirReal7808/hifi-companion/pull/1) (`cursor/eq-visual-glass-2953` → `main`), [#2](https://github.com/SirReal7808/hifi-companion/pull/2) (`cursor/eq-fit-laptop-970c` → that). Work on top of `v0.2`.

```bash
git fetch origin tag v0.2
git checkout v0.2   # or cursor/eq-fit-laptop-970c
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
xcodegen generate   # only if project.yml changed
xcodebuild -scheme "HiFi Companion" -configuration Release -derivedDataPath build
pkill -x HiFiCompanion 2>/dev/null || true
mkdir -p ~/Applications
rm -rf ~/Applications/HiFiCompanion.app
ditto "build/Build/Products/Release/HiFiCompanion.app" ~/Applications/HiFiCompanion.app
open ~/Applications/HiFiCompanion.app
```

Always ditto into **`~/Applications/HiFiCompanion.app`** so System Audio Recording TCC matches the binary. Launch prints `stamp=eq-footer-compact-v4 ver=19 exe=…/Applications/HiFiCompanion.app/…`. If the stamp is missing, Mert is running a stale copy.

Debug open-EQ (Mac UI tests): `--show-eq`, `--eq-unlock-controls`, `--eq-enable-pt`. Smokes: `--smoke-passthrough`, `--smoke-rate-eq`, `--smoke-sweep`.

## Do not break

- **Compact footer** — no dark footer strip; Add Band / Reset on the window background; equal pad above/below; **never clip** the right glass corners or drop shadow (`.clipped()`, overlay, ExactHeight squeeze). Shot: [docs/media/eq-footer-compact.jpg](docs/media/eq-footer-compact.jpg).
- **Process tap only** — no BlackHole hop, no switching the system default output, no Microphone prompt.
- **Exclusive Music lock** — switch SB only while Music is the sole audible client on the DAC.
- **Sweep engine** — never leave the on-demand DAC `AVAudioEngine` running idle (silences Pass-through Music).
- **Exact height** — width 900; `min == max` H(N); no green zoom; no PreferenceKey layout loop.
- **Signed zero** — exact 0 dB prints `0.0`, never `+0.0` / `-0.0`.
- **Listening tests** — Mert plays music himself. Do not start Music or YouTube for those.
- **Language** — Mert may write Turkish; product UI and repo docs stay English. Write **SB** in caps.
- **Scope** — PEQ + SB match + sweep. Not a player. Android is later. Do not share the Mac audio driver.

If Mert says “0.2 sürümüne geri dönelim”, restore tag `v0.2`. Same for `v0.1` (pre–side-panel UX).
