# Releases

Version history, git tags, archived app builds, how to roll back, and how to bump the version.

## Versions

| Release | Tag → commit | Launch stamp / build | Archived app | What it is |
|---|---|---|---|---|
| **0.2** (current) | `v0.2` → `a49ad4b` | `eq-footer-compact-v4` / 19 | `~/Applications/HiFiCompanion-0.2.app` | Approved EQ: compact footer, laptop fit, side-panel UX |
| **0.1** | `v0.1` → `fd09485` | `window-chrome-v7` / 7 | `~/Applications/HiFiCompanion-0.1.app` | Last working EQ **before** the side-panel UX redesign |

Both tags are annotated and reachable from `main`. **Do not delete them** unless Mert retires a snapshot.

Note: the tagged builds still report `CFBundleShortVersionString` **0.1.0**. The marketing version became `0.2.0` when versioning moved to `project.yml` (2026-10-28, after the tag); the build number (19) is unchanged.

### 0.2 — 2026-10-27

On top of 0.1:

- Side-panel UX: glass knobs on OUTPUT GAIN and GAIN LEVEL, ALL CAPS labels, FIX PEAK / FIX DIP, no steppers, framed OUTPUT GAIN like GAIN LEVEL, hairline above TONE GENERATOR, soft knob scroll with inverted trackpad, SF Pro.
- Laptop fit: H(N) clamps to `visibleFrame − 16`; graph shrinks first; middle hugs `max(band list, measured side)`.
- **Compact footer (locked):** no footer strip; Add Band / Reset on the window background; equal pad above / below; side glass corners and shadow unclipped.

### 0.1 — 2026-10-27

Menu-bar SB matching with exclusive-Music lock, process-tap Pass-through, 10-band PK / LS / HS PEQ, response graph + sweep + Peak / Dip, frosted-glass EQ window with exact height and no zoom, profiles, undo / redo, Auto output gain, Bypass + Gain Match. Window chrome: normal `NSWindow`, standard close button.

### Since 0.2 (on `main`, no app code changes)

- 2026-10-28: onboarding docs pack, `CLAUDE.md`, versioning moved to `project.yml` (0.2.0 / 19), `main` fast-forwarded to the former live branch `cursor/eq-fit-laptop-970c` (PRs #1–#4 merged), old `cursor/*` branches deleted, docs reorganized.

## Rollback

Trigger phrases: "0.2 sürümüne geri dönelim", "0.1 sürümüne geri dönelim".

The tags contain the **app** only — the docs (`AGENTS.md`, `docs/`) were added after them. Prefer the archived binary; if you check out a tag, return to `main` for the docs afterwards.

**Run an archived build (no git change):**

```bash
pkill -x HiFiCompanion 2>/dev/null || true
open ~/Applications/HiFiCompanion-0.2.app   # or HiFiCompanion-0.1.app
```

**Make an archive the installed app:**

```bash
pkill -x HiFiCompanion 2>/dev/null || true
rm -rf ~/Applications/HiFiCompanion.app
ditto ~/Applications/HiFiCompanion-0.2.app ~/Applications/HiFiCompanion.app
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

1. Edit `project.yml`: `MARKETING_VERSION` (user-facing, e.g. `0.3.0`) and `CURRENT_PROJECT_VERSION` (build number, increment by 1 for every build Mert installs).
2. `xcodegen generate`. `Info.plist` picks both up via `$(MARKETING_VERSION)` / `$(CURRENT_PROJECT_VERSION)`. Never hand-edit `project.pbxproj`.
3. When the EQ window changes visibly, also change `PEQPanelController.buildStamp` so the launch log proves which binary runs.
4. Build, test, install, and check the launch log `stamp=` / `ver=`.

## Cutting a release

When Mert approves a build as a release:

1. Make sure it is merged on `main`.
2. Tag it: `git tag -a v0.N -m "HiFi Companion 0.N — <summary>" && git push origin v0.N`.
3. Archive the installed build: `ditto ~/Applications/HiFiCompanion.app ~/Applications/HiFiCompanion-0.N.app`.
4. Add a row and a section to this file.
