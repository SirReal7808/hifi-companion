# Working agreement

How to work on HiFi Companion with Mert, the project owner. These are standing rules; follow them without asking again.

## Language

- **Chat with Mert in Turkish.** English technical terms are welcome; Mert reads English.
- **Everything in the app and repo is English:** UI strings, code, comments, commit messages, PR text, docs.
- Write **SB** (sample rate + bit depth) in caps.
- History: earlier docs said "reply in English". That was a workaround for Cursor's weak Turkish and no longer applies.

## Git and GitHub

- Repo: https://github.com/SirReal7808/hifi-companion (public since 2026-11-19). `gh` is installed and signed in on Mert's Mac.
- `main` is the live line. Branch from `main`, open a PR back to `main`.
- **Merge only after Mert approves** the PR. Commit and push to your own branch freely.
- Run the unit tests locally before opening a PR and state the result in it. GitHub Actions CI runs on pull requests and pushes to `main` (public repo; manual runs via Actions → Tests → Run workflow); do not wait on it.
- Never force-push or rewind `main`. Never delete or move release tags (`v0.1` … `v0.4.2`).
- Delete a branch only after its PR is merged (Mert's OK covers the merge, not other sessions' branches); keep `spike/*`.
- End commit messages / PR bodies with the attribution your tool requires.

## Sessions and workflow

- **One task per session** (Mert, 2026-11-01). State lives in [status.md](status.md), the topic docs, memory and PRs — not in chat history; long chats get slow and expensive. Fixes from Mert's test of that task stay in the same session; the next task starts a new one, where Mert just says "kaldığımız yerden devam" and the agent takes the first item in `status.md` → Next up.
- Every task runs the same loop: pick from `status.md` → branch → implement → local tests → reviewer (where relevant) → install → PR with the test result → Mert's click-through test → merge on Mert's OK. Claude Code runs it with `/task` ([.claude/skills/task/SKILL.md](../.claude/skills/task/SKILL.md)); other tools follow that file's steps by hand.
- **Every session ends with a handoff** — when Mert says so ("handoff", "oturumu kapat") or when the task is merged: update `status.md` (Now, Next up, Backlog, Decided), the topic docs and memory; tidy branches; tell Mert the next task and how to start it. Claude Code runs it with `/handoff` ([.claude/skills/handoff/SKILL.md](../.claude/skills/handoff/SKILL.md)).
- Parallel sessions each work in their own worktree and branch, and never edit files another session's branch is changing.

## Machine and install

- Mert's Mac runs **macOS 27** (Xcode 27.1, Homebrew, XcodeGen, `gh`). Accessibility appears as "Device Control and Data Access".
- Drive build / launch / install yourself instead of asking Mert to run steps.
- Always install to **`~/Applications/HiFiCompanion.app`** — System Audio Recording permission is tied to that path and signature. Spotlight happily launches a stale copy, so confirm the launch log `stamp=` / `ver=` / `exe=` after every install. Commands: [AGENTS.md](../AGENTS.md#build-test-install).
- Keep the archived builds, zipped in `~/Library/Application Support/HiFiCompanion/Archives/` ([releases.md](releases.md)). Only `~/Applications/HiFiCompanion.app` may exist as an unzipped app, so Spotlight shows a single HiFi Companion.

## Listening tests

Mert does the listening tests ("müzik çalma testi") until saying otherwise. **Do not start Music or YouTube** for them. Engineering checks with `afplay`, smokes, and `--show-eq` are fine — but they run the app against the real DAC, so avoid them while Mert is listening.

## Audio policy

- **Apple Music Mode** switches the DAC only while Music is the **sole** app sending audio there; it pauses while others are audible (the panel shows a gray **Paused**) and catches up when they stop. Rate changes happen at track changes, never mid-track ([audio-path.md](audio-path.md#sb-matching-apple-music-mode)).
- Users must **not** see a Microphone prompt. The equalizer uses a process tap, not BlackHole and not the laptop mic. The only capture prompt is **System Audio Recording**, and it stays documented ([audio-path.md](audio-path.md#permission-not-the-microphone)).
- A bundled virtual device (to drop the capture prompt) is a later goal. Do not reintroduce BlackHole as the hop.
- The app may switch the macOS output only to the user's preferred hardware device (0.3 redesign); the old "never change the default output" rule came from the BlackHole hop and is retired.
- Do not claim "bit-perfect" in the UI. Use "Direct" with the conditions listed. (The flat-equalizer path is measured bit-exact by the null test on USB outputs, but the UI cannot prove it per session.)

## Product scope

Stay within system-wide PEQ + SB match + sweep ([product.md](product.md#vision-mert-2026-10-28)). The EQ is the core; Apple Music Mode is an independent toggle. Do not add player features. Mert keeps the Auto EQ idea and other platforms for later — do not start them unprompted.

## Visual and EQ window

The EQ window spec, including the **locked compact footer**, is [eq-window.md](eq-window.md). The target is **native Liquid Glass, dark first** (agreed 2026-10-31, shipped in 0.4.0): system materials, glass capsules, one grouped band container. The menu panel and Settings use the same native look. The old sparse flat light concept stays rejected.

## Revert phrases

"<version> sürümüne geri dönelim" (e.g. "0.4.0 …", "0.2 …") = restore that release ([releases.md](releases.md#rollback)).

## Do not re-litigate

The fixes in [pitfalls.md](pitfalls.md) were paid for with regressions. Keep them unless Mert asks otherwise.
