# Working agreement

How to work on HiFi Companion with Mert, the project owner. These are standing rules; follow them without asking again.

## Language

- **Chat with Mert in Turkish.** English technical terms are welcome; Mert reads English.
- **Everything in the app and repo is English:** UI strings, code, comments, commit messages, PR text, docs.
- Write **SB** (sample rate + bit depth) in caps.
- History: earlier docs said "reply in English". That was a workaround for Cursor's weak Turkish and no longer applies.

## Git and GitHub

- Repo: https://github.com/SirReal7808/hifi-companion (private). `gh` is installed and signed in on Mert's Mac.
- `main` is the live line. Branch from `main`, open a PR back to `main`.
- **Merge only after Mert approves** the PR. Commit and push to your own branch freely.
- Run the unit tests locally before opening a PR and state the result in it. GitHub Actions CI is manual-only (Actions → Tests → Run workflow); do not wait on it.
- Never force-push or rewind `main`. Never delete tags `v0.1` / `v0.2`.
- End commit messages / PR bodies with the attribution your tool requires.

## Sessions and workflow

- Every phase or task runs the same loop: branch → implement → local tests → reviewer (where relevant) → install → PR with the test result → Mert's click-through test → merge on Mert's OK. Claude Code runs it with `/phase` ([.claude/skills/phase/SKILL.md](../.claude/skills/phase/SKILL.md)); other tools follow that file's steps by hand.
- **Start each large phase in a fresh session.** State lives in the repo docs, memory and PRs, not in chat history; long chats get slow and expensive. Keep small follow-ups (a fix from Mert's test, a doc tweak) in the session that did the work.
- Parallel sessions each work in their own worktree and branch, and never edit files another session's branch is changing.

## Machine and install

- Mert's Mac runs **macOS 27** (Xcode 27.1, Homebrew, XcodeGen, `gh`). Accessibility appears as "Device Control and Data Access".
- Drive build / launch / install yourself instead of asking Mert to run steps.
- Always install to **`~/Applications/HiFiCompanion.app`** — System Audio Recording permission is tied to that path and signature. Spotlight happily launches a stale copy, so confirm the launch log `stamp=` / `ver=` / `exe=` after every install. Commands: [AGENTS.md](../AGENTS.md#build-test-install).
- Keep the archived builds, zipped in `~/Library/Application Support/HiFiCompanion/Archives/` ([releases.md](releases.md)). Only `~/Applications/HiFiCompanion.app` may exist as an unzipped app, so Spotlight shows a single HiFi Companion.

## Listening tests

Mert does the listening tests ("müzik çalma testi") until saying otherwise. **Do not start Music or YouTube** for them. Engineering checks with `afplay`, smokes, and `--show-eq` are fine — but they run the app against the real DAC, so avoid them while Mert is listening.

## Audio policy

- **Apple Music mode** switches the DAC only while Music is the **sole** app sending audio there; lock while others are audible; unlock when they stop. The menu documents this.
- Users must **not** see a Microphone prompt. Pass-through is a process tap, not BlackHole and not the laptop mic. The only capture prompt is **System Audio Recording**, and it stays documented ([audio-path.md](audio-path.md#permission-not-the-microphone)).
- A bundled virtual device (to drop the capture prompt) is a later goal. Do not reintroduce BlackHole as the hop.
- The app may switch the macOS output only to the user's preferred hardware device (0.3 redesign); the old "never change the default output" rule came from the BlackHole hop and is retired.
- Do not claim "bit-perfect" in the UI — it cannot be verified without tapping the samples. Use "Direct" with the conditions listed.

## Product scope

Stay within system-wide PEQ + SB match + sweep ([product.md](product.md#vision-mert-2026-10-28)). The EQ is the core; Apple Music mode is an independent toggle; Pass-through and the lock are temporary and will be redesigned with Mert. Do not add player features. Mert keeps the Auto EQ idea and other platforms for later — do not start them unprompted.

## Visual and EQ window

The EQ window spec, including the **locked compact footer**, is [eq-window.md](eq-window.md). Match the reference mockups' intent (soft frosted glass, cushion controls, soft graph wash). The sparse flat light concept is rejected.

## Revert phrases

"0.1 sürümüne geri dönelim" / "0.2 sürümüne geri dönelim" = restore that release ([releases.md](releases.md#rollback)).

## Do not re-litigate

The fixes in [pitfalls.md](pitfalls.md) were paid for with regressions. Keep them unless Mert asks otherwise.
