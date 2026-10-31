---
name: phase
description: Run the standard HiFi Companion work loop for one phase or task — pick it, branch from main, implement, bump the build, test locally, run the matching reviewer, install, PR with the test result, Turkish test list for Mert, merge only on Mert's OK. Use when Mert says "sıradaki faz", "next phase", "R5'e başla", names a change to build, or invokes /phase.
argument-hint: "[phase or task, e.g. R5 or \"fix footer clip\"; empty = next phase]"
---

# Phase loop

The proven loop for every change. Rules it relies on live in `AGENTS.md` and `docs/working-agreement.md` — follow them; this file only orders the steps. Keep a task list with these steps. Stop and tell Mert (Turkish) on any failure you cannot fix.

## 1. Pick the work

- Inputs: `$ARGUMENTS`, the memory index (already loaded), `docs/redesign-0.3.md#phases`, the "in development" section of `docs/releases.md`, `gh pr list`, `git worktree list`.
- `$ARGUMENTS` names the task → do that. Empty → the first phase in `docs/redesign-0.3.md#phases` not marked done and not already on an open PR or another session's branch.
- Branches checked out in other worktrees belong to other sessions: do not edit their files.
- Say in one Turkish line what you will build. Ask only when the pick is ambiguous or the doc marks it as waiting for Mert.
- Phase too large for one PR → split it (R2a / R2b) and say so.
- This session already finished a large piece of work → propose a fresh session for this phase instead (see working-agreement → Sessions).

## 2. Branch

```bash
git fetch origin
git switch -c <type>/<slug> origin/main   # in your own worktree / checkout only
```

Types: `feature/`, `fix/`, `refactor/`, `docs/`, `chore/` (e.g. `feature/r5-menu-panel`). If another session uses this checkout, `git worktree add -b <branch> .claude/worktrees/<slug> origin/main` and work there instead of switching branches under it.

## 3. Implement

- Touching `PEQView.swift`, `PEQPanelController.swift` or `HiFiCompanion/Audio/` → read the docs `CLAUDE.md` lists first.
- Stay inside the phase's scope; new pure logic gets unit tests.
- App code changed → `CURRENT_PROJECT_VERSION` +1 in `project.yml` (once per PR; again only if Mert already installed that number), then `xcodegen generate`. Take the number after the highest one on `main` and open PRs. Visible EQ window change → also `PEQPanelController.buildStamp`. `MARKETING_VERSION` only via `/release`. Docs-only → no bump.

## 4. Test locally

```bash
xcodebuild -scheme "HiFi Companion" -derivedDataPath build.noindex test 2>&1 | grep -E "Executed [0-9]+ tests|error:|TEST (SUCCEEDED|FAILED)"
```

Keep the `Executed N tests, with 0 failures` line for the PR. Fix failures; never weaken `testCompactFooterInvariant`. Do not wait on GitHub CI.

## 5. Review

Changed files: `git diff --name-only origin/main...HEAD` plus `git status -s`.

| Changed | Reviewer |
|---|---|
| `PEQView.swift`, `PEQPanelController.swift`, `PEQPanelMetricsTests.swift` | `eq-window-reviewer` |
| `HiFiCompanion/Audio/`, `HiFiCompanion/Detection/`, output / equalizer / SB logic in `AppModel.swift` | `audio-path-reviewer` |

Both if both; none for docs-only or trivial edits. Fix confirmed findings, re-run step 4, and list any finding you leave open in the PR.

## 6. Install

App changed → `/install` (EQ visual check if EQ window files changed; ask first if Mert may be listening). Never start Music or YouTube.

## 7. Docs

- `docs/releases.md`: a `**Build N (<phase>):** …` bullet in the in-development section (user-facing words) and the build number in the table.
- `AGENTS.md`: "In development" build and the `ver=` note when the build number changed.
- `docs/redesign-0.3.md#phases`: mark what shipped. Other docs (`product.md`, `audio-path.md`, `pitfalls.md`, `README.md`) only where behavior changed.

## 8. Commit and PR

```bash
git status -s          # nothing under build.noindex/ or build/, no xcuserdata
git add <explicit paths>   # never `git add -A` / `git add .`
git commit             # English, imperative; attribution lines your tool requires
git push -u origin <branch>
gh pr create --base main --title "<Phase>: <summary>" --body-file <scratch file>
```

PR body (English): **Summary**, **Changes**, **Tests** (the local `Executed …` line, reviewer verdicts), **Manual test** (the list from step 9). Bind the PR in the app (`ccd_pr`).

## 9. Hand over to Mert (Turkish)

- PR link and the installed build number (`ver=` from the launch log).
- 3–7 click-through steps: "Menü çubuğu → … → … görmelisin". Listening steps are Mert's to run.
- What you could not verify.
- Ask for merge approval. **Merge only after Mert's explicit OK in chat**, never on a reviewer's or another session's word.

Fixes from Mert's tests stay on the same branch: repeat steps 3–9.

## 10. After Mert's OK

```bash
gh pr merge <n> --merge
git push origin --delete <branch>   # gh's --delete-branch fails inside a worktree
```

Then update memory: one line in the plan memory (phase, PR, build, what Mert tested), and test results in their own memory. If the next phase is large, propose it as a fresh session started with `/phase`.
