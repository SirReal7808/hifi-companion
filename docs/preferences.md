# Operator preferences (product)

How to work on HiFi Companion with Mert. Product rules, not a chat-tool profile.

## Product identity

- Name: **HiFi Companion**. Repo: https://github.com/SirReal7808/hifi-companion
- It is a **system-wide PEQ**, Apple Music **SB** match, and a **sine sweep**. It is not a player. Leave out features most listeners never use (internet radio, discovery, lyrics).
- Stops at macOS until Mert asks to start Android. Share filter math later. Do not share the Mac audio driver.

## Mert / language

- Mert is the user. Chat in **Turkish**; English technical terms are fine. Product UI, code, comments, commit messages, and repo docs stay **English**.
- Write **SB** (caps) for sample rate and bit depth.
- “0.1/0.2 sürümüne geri dönelim” means restore that tagged snapshot — see [eq-v0.1-revert.md](eq-v0.1-revert.md) and [eq-v0.2-revert.md](eq-v0.2-revert.md).

## Machine

- His Mac runs **macOS 27**. Prefer driving build/launch/install yourself (Terminal on that Mac) instead of asking him to run those steps.
- Accessibility is listed as Device Control and Data Access.
- Install path is always `~/Applications/HiFiCompanion.app` (TCC). Confirm launch `stamp=` / `ver=` / `exe=`.

## Audio policy

- **Apple Music mode** switches the DAC only while Music is the **sole** app sending audio there; lock while others are audible; unlock when they stop. Document this in the product (already in the menu note).
- Users should **not** need a Microphone privacy prompt. Pass-through is a process tap, not BlackHole and not the laptop mic. If a capture prompt remains, it must be **System Audio Recording**, and it must stay documented (see [audio-path.md](audio-path.md)).
- A bundled virtual device (to replace any capture prompt) is a later release goal — do not reintroduce BlackHole as the hop.

## Listening tests

Mert does listening tests himself (“müzik çalma testi”) until he says otherwise. **Do not start Music or YouTube** for those tests.

## Visual / EQ window

- Match user refs: [media/hifi-companion-eq-user-ref-light.png](media/hifi-companion-eq-user-ref-light.png) and [media/hifi-companion-eq-user-ref-dark.png](media/hifi-companion-eq-user-ref-dark.png). Soft frosted glass, cushion controls, soft graph wash. The sparse flat light concept was **rejected**.
- System light/dark + menu bar Appearance override (System / Light / Dark).
- Interaction: [eq-window-decisions.md](eq-window-decisions.md). Visual: [eq-visual-target.md](eq-visual-target.md).
- **Footer locked 2026-10-27:** no separate dark footer bar; Add Band and Reset on the main window with equal pad above and below; right Output/Tone glass keeps bottom rounded corners and drop shadow fully visible. Approved shot: [media/eq-footer-compact.jpg](media/eq-footer-compact.jpg). Cursor rule: [`.cursor/rules/eq-compact-footer.mdc`](../.cursor/rules/eq-compact-footer.mdc).
