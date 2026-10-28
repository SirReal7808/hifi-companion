# CLAUDE.md

Claude Code loads this file automatically. The single onboarding entry for this repo is `AGENTS.md` (shared with other AI tools); it is imported below so its rules apply in full. When project rules change, edit `AGENTS.md` and `docs/`, not this file.

@AGENTS.md

## Claude Code notes

- Before changing `PEQView.swift`, `PEQPanelController.swift`, or anything under `HiFiCompanion/Audio/`, read `docs/eq-window.md`, `docs/audio-path.md`, and `docs/pitfalls.md`.
- Use `gh` for PRs. Merging into `main` needs Mert's explicit approval in chat.
- `/install` builds, installs and verifies the app (optional EQ screenshot check); `/release` cuts a version.
- Before committing changes to the EQ window, run the `eq-window-reviewer` subagent; for `HiFiCompanion/Audio`, `Detection`, or Pass-through / SB code in `AppModel.swift`, run `audio-path-reviewer`. Skip them for docs-only or trivial edits.
- `.claude/hooks/guard.sh` blocks hand edits to `project.pbxproj` and direct / force pushes to `main`.
