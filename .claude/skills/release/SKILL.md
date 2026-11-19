---
name: release
description: Cut a HiFi Companion release (0.MINOR.PATCH) after Mert approves a build — version bump, tag, archive build, releases.md. Use when Mert says a build is approved / "release it" / "sürüm çıkar", or asks to bump the version.
---

# Release HiFi Companion

Scheme (docs/releases.md): every release bumps PATCH (0.2.1 → 0.2.2); Mert decides when MINOR goes up (0.3.0). Build number (`CURRENT_PROJECT_VERSION`) +1 for every build Mert installs.

## Bump only (start of a new version's work)

1. On a branch: edit `MARKETING_VERSION` / `CURRENT_PROJECT_VERSION` in `project.yml`, then `xcodegen generate`. Never edit `project.pbxproj` by hand.
2. Add a `### 0.x.y — in development (build N)` section and table row to `docs/releases.md`; update "In development" in `AGENTS.md` and the status line in `README.md`.

## Cut a release (Mert approved the installed build)

Confirm with Mert which version is being released before tagging — tags are permanent.

1. The release commit is merged on `main`; the installed app (`~/Applications/HiFiCompanion.app`) is that build — check its `CFBundleVersion`.
2. Tag and push:
   ```bash
   git checkout main && git pull --ff-only
   git tag -a v0.x.y -m "HiFi Companion 0.x.y — <one-line summary>"
   git push origin v0.x.y
   ```
3. Archive as a zip — never a second `.app` (Spotlight would list it): `ditto -c -k --keepParent ~/Applications/HiFiCompanion.app ~/Library/Application\ Support/HiFiCompanion/Archives/HiFiCompanion-0.x.y.app.zip`
4. Package for download (from 0.5.0; [docs](../../../docs/releases.md#packaging-a-release)): write the user-facing release notes (English Markdown, from the `docs/releases.md` section) to a scratch `notes.md`, then run in the background (two notarizations, a few minutes):
   ```bash
   scripts/package-release.sh 0.x.y --notes <scratch>/notes.md
   ```
   It refuses a version whose `.dmg` already exists. On a notarization rejection it prints Apple's log; fix the cause, never ship a dry run.
5. GitHub Release with the new `.dmg` and the regenerated `appcast.xml` (Sparkle's feed is `releases/latest/download/appcast.xml`, so the release must be marked latest, which `gh` does by default):
   ```bash
   R=~/Library/Application\ Support/HiFiCompanion/Releases
   gh release create v0.x.y "$R/HiFiCompanion-0.x.y.dmg" "$R/appcast.xml" --title "HiFi Companion 0.x.y" --notes-file <scratch>/notes.md
   ```
   Check the download: `curl -sIL <dmg url> | grep -i '^HTTP'`.
6. Docs PR: in `docs/releases.md` turn the "in development" row/section into the released one (tag → commit, archive path, date); `AGENTS.md` "Latest release"; `README.md` status.

Never delete or move existing tags.
