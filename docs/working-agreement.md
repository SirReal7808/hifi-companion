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
- Never force-push or rewind `main`. Never delete tags `v0.1` / `v0.2`.
- End commit messages / PR bodies with the attribution your tool requires.

## Machine and install

- Mert's Mac runs **macOS 27** (Xcode 27.1, Homebrew, XcodeGen, `gh`). Accessibility appears as "Device Control and Data Access".
- Drive build / launch / install yourself instead of asking Mert to run steps.
- Always install to **`~/Applications/HiFiCompanion.app`** — System Audio Recording permission is tied to that path and signature. Spotlight happily launches a stale copy, so confirm the launch log `stamp=` / `ver=` / `exe=` after every install. Commands: [AGENTS.md](../AGENTS.md#build-test-install).
- Keep the archived builds `~/Applications/HiFiCompanion-0.1.app` and `HiFiCompanion-0.2.app` ([releases.md](releases.md)).

## Listening tests

Mert does the listening tests ("müzik çalma testi") until saying otherwise. **Do not start Music or YouTube** for them. Engineering checks with `afplay`, smokes, and `--show-eq` are fine — but they run the app against the real DAC, so avoid them while Mert is listening.

## Audio policy

- **Apple Music mode** switches the DAC only while Music is the **sole** app sending audio there; lock while others are audible; unlock when they stop. The menu documents this.
- Users must **not** see a Microphone prompt. Pass-through is a process tap, not BlackHole and not the laptop mic. The only capture prompt is **System Audio Recording**, and it stays documented ([audio-path.md](audio-path.md#permission-not-the-microphone)).
- A bundled virtual device (to drop the capture prompt) is a later goal. Do not reintroduce BlackHole as the hop.

## Product scope

Stay within system-wide PEQ + SB match + sweep ([product.md](product.md)). Do not add player features. macOS only until Mert asks for Android.

## Visual and EQ window

The EQ window spec, including the **locked compact footer**, is [eq-window.md](eq-window.md). Match the reference mockups' intent (soft frosted glass, cushion controls, soft graph wash). The sparse flat light concept is rejected.

## Revert phrases

"0.1 sürümüne geri dönelim" / "0.2 sürümüne geri dönelim" = restore that release ([releases.md](releases.md#rollback)).

## Do not re-litigate

The fixes in [pitfalls.md](pitfalls.md) were paid for with regressions. Keep them unless Mert asks otherwise.
