---
name: handoff
description: Close a HiFi Companion session so the next one starts clean — record the outcome in docs/status.md, refresh Claude's memory, check the repo is tidy (branches, PRs, worktree, installed build), commit the status update, and give Mert a short Turkish summary plus the prompt to start the next session. Use when Mert says "handoff", "oturumu kapat", "bitirelim", "devret", "sonraki session'a hazırla", after a task's PR is merged (the /task loop ends with it), or when the session's work is done and nothing is in flight.
---

# Handoff

Ends a session. The next session must be able to start from `AGENTS.md` → `docs/status.md` → memory, with no chat history. Keep a task list with these steps. Do not start new work here; anything found goes into `docs/status.md`.

## 1. Collect the facts

```bash
git fetch -q origin --prune
git status -s
git branch --show-current
gh pr list --state open
git worktree list
git log --oneline -5 origin/main
/usr/libexec/PlistBuddy -c 'Print CFBundleVersion' ~/Applications/HiFiCompanion.app/Contents/Info.plist
```

Also note from this session: what was done (PRs, commits, builds), what Mert tested and the result, decisions Mert made, bugs or ideas that came up, and what is unfinished.

## 2. Repo hygiene

- Uncommitted changes that belong to this session's task: commit them to its branch (explicit paths, never `git add -A`). Anything else: ask Mert, never discard.
- This session's merged branches: delete the remote branch (`git push origin --delete <branch>`) if the merge left it. Never delete branches of other sessions, `spike/*`, `main`, or tags.
- Open PRs: each one is either waiting on Mert (say so in status) or superseded (say so and ask before closing).
- The installed app's build number matches what `docs/status.md` says is installed.
- Nothing under `build.noindex/`, `build/` or `xcuserdata` is tracked.

## 3. Update `docs/status.md`

- **Now:** release, build in development, installed build, open PRs, what waits on Mert.
- **Next up:** remove what is done (it lives in `releases.md` / the PR). Add new bugs or tasks with enough detail to start cold: symptom, where in the code, suspects, done-when. Keep it ordered; first item = what the next session should do.
- **Backlog / Later:** add ideas that came up; Mert has not scheduled them.
- **Decided — do not re-propose:** add any proposal Mert declined, with the date.
- Update `_Last updated:_`.
- Keep the file short. Detail that is permanent belongs in the topic docs (`audio-path.md`, `pitfalls.md`, …); update those too if behavior changed.

Also check `AGENTS.md` → Current state still matches (release, in-development build, stamp, archives).

## 4. Update memory

Memory lives in Claude's memory directory (the index `MEMORY.md` is loaded every session). It holds only what the repo does not: who Mert is, how he wants to work, his feedback and decisions, and pointers. **Never** copy the backlog or history into memory: point to `docs/status.md`.

- Fix or delete memories that are now wrong (a bug fixed, a decision changed).
- Add feedback Mert gave this session (corrections and confirmed approaches) to an existing file when one covers it.
- Keep `project-state` memory to a few lines: latest release, in-development build, "see docs/status.md".
- Each `MEMORY.md` line stays one short hook.

## 5. Commit the handoff

Docs-only changes (status, topic docs) go on a `docs/handoff-<yyyy-mm-dd>` branch from `origin/main` (or onto the session's open PR branch if it is still open), committed with explicit paths, pushed, and opened as a PR. Merging still needs Mert's OK; say so.

## 6. Tell Mert (Turkish, short)

- What was done this session (PR links, build, release).
- What is open and who it waits on.
- The next task from `docs/status.md` → Next up. To start it Mert only opens a **new session** and says "kaldığımız yerden devam" — no task name needed; `/task` picks the first Next up item.
- Model for that session: Opus for audio path, data, release or big decisions; Sonnet for UI fixes and docs.
