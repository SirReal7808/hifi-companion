# Redesign 0.3 — output, signal path, menu bar

Agreed with Mert on 2026-10-28. Replaces the development-time Pass-through / pin / "Locked" design (see [product.md](product.md#vision-mert-2026-10-28)). Nothing here is built yet; phases R1–R5 below each land as their own PR. Target version **0.3.0** (Mert decides when to release).

**Guiding principle:** easy to use, simple UI, but feature-rich. Every decision below is weighed against that.

## Why

Mert's DAC tests (0.2.1) confirmed the pin model breaks in real use:

- Unplugging the pinned DAC moved EQ onto the MacBook speakers, while the menu still said "DAC".
- Replugging did not recover. Sound came back only after choosing the DAC in macOS, and EQ only after toggling Pass-through off and on ("Playback drifted to device …").
- Choosing **System Default** disabled Pass-through, so there was no EQ at all.

The root cause is the assumption that the user pins one DAC and keeps using it.

## Concepts

| Today | 0.3 |
|---|---|
| Pin a DAC (device list in the menu) | **Output**: follow macOS, or a preferred device (Settings + menu) |
| Pass-through toggle | **Parametric Equalizer** on/off (on = process tap, off = HiFi Companion is not in the audio path) |
| Exclusive-Music lock, "Locked" | **Apple Music Mode** on/off. The "other app is playing" state appears in the signal path, never as a "Locked" / "Waiting" label. |
| Developer status lines in the menu | One **signal path** line; details on hover; developer info under Diagnostics |
| One EQ curve | **Per-device profiles** |

## Output

- **Default: follow the macOS output.** Whatever macOS plays to is where the equalizer works and what Apple Music Mode matches.
- **Preferred device.** Once the user picks a device in HiFi Companion (menu or Settings), it becomes the preferred output:
  - While it is connected, HiFi Companion makes it the macOS output.
  - When it is not connected, or is unplugged, HiFi Companion follows the macOS output (macOS falls back by itself).
  - When it is plugged back in, it becomes the macOS output again.
  - Choosing "System Default" clears the preference.
- HiFi Companion switches the macOS output **only** to the user's preferred hardware device — never to a virtual / loopback device, never on its own initiative otherwise.
- Every output change re-targets the tap (when the equalizer is on) and loads that device's profile.

## Parametric Equalizer

- One on/off switch. Off removes the process tap entirely, so HiFi Companion is not in the audio path.
- On: the process tap of the current output device → private aggregate → PEQ → the same device, as today (`docs/audio-path.md`). The tap is rebuilt when:
  - the output device changes, or the device is added, removed, or goes alive/dead
  - the sample rate changes
  - the Mac wakes from sleep
- **Exclusive (hog-mode) players** (Qobuz, Audirvana, Roon "exclusive"): detected via `kAudioDevicePropertyHogMode`.
  - The equalizer cannot run and its switch shows **"Unavailable — Qobuz exclusive"**.
  - If the equalizer was on, it suspends and resumes by itself when the player releases the device.
- **Per-device profiles:** each output device remembers its own profile; switching device switches profile; a device seen for the first time starts flat. The EQ window edits the current device's profile. Profile storage gets a schema version (review item A7).

## Apple Music Mode

- Independent on/off switch. It matches the current output device's SB to the Apple Music track.
- Same rule as today: switch only while Music is the only app playing to that device (a rate change affects every app on the device).
- Tooltip (hover and wait) explains what it does.

## Signal path

Shown whether or not the equalizer is on. Reading device state is observe-only and never touches the audio stream.

- **One line with a colored dot** in the menu panel, for example `● Apple Music → Parametric Equalizer → DX5 II`.
- **Hover** shows the full chain, for example `Apple Music · 96 kHz / 24-bit ALAC → Parametric Equalizer → DX5 II · 96 kHz / 24-bit`.
- The dot:

| Dot | Label | When |
|---|---|---|
| Green | **Direct** | Equalizer off (or exclusive player), one app playing, rates match, no digital volume attenuation |
| Blue | **Parametric Equalizer** | Equalizer processing the signal (intentionally colored) |
| Yellow | **Resampled** | Source and device rates differ (e.g. Music 96 kHz while Chrome also plays and the DAC stays at 44.1) |

- We do **not** say "bit-perfect": we cannot verify samples without tapping them. The Direct tooltip lists which conditions are met.
- The source format is known for Apple Music (log detection). For other apps we show the app name and the device format: `Qobuz → DX5 II · 96 kHz / 24-bit`. An exclusive player shows as `Qobuz (exclusive) → DX5 II · 192 kHz / 24-bit`.

## Menu bar

**Title:** the logo; until it exists, the text "HiFi Companion". In Settings the user can add any of **Device**, **SB**, **Profile** (joined with " · ", long names truncated); with none selected, only the logo shows.

**Panel** (MenuBarExtra `.window`, same glass language as the EQ window):

```
 DX5 II                               44.1 kHz / 24-bit
 ● Apple Music → Parametric Equalizer → DX5 II       (hover: full chain)
 ───────────────────────────────────────────────
 Parametric Equalizer                          [on]
 Profile                          Moondrop Chu   ▸   (submenu: switch without opening the window)
 Open Equalizer…                                ⌘E
 ───────────────────────────────────────────────
 Apple Music Mode                              [on]   (hover: explanation)
 ───────────────────────────────────────────────
 Output                          System Default  ▸
 Settings…                                      ⌘,
 Quit HiFi Companion                            ⌘Q
```

## Settings window

- **General:** launch at login, menu bar title items (Device / SB / Profile), Appearance (System / Light / Dark).
- **Output:** preferred device, and the per-device profile list.
- **Apps:** apps excluded from the equalizer (e.g. video calls).
- **Diagnostics:** today's developer lines (Signal meter, path, test tone, detection state).

## First run

A short explainer before the System Audio Recording prompt. Draft:

> **Welcome to HiFi Companion.** To equalize what you hear, macOS will ask for **System Audio Recording**. This lets HiFi Companion process other apps' sound on its way to your DAC. It is not the microphone, and nothing is recorded or saved. You can turn the equalizer off at any time; when it's off, HiFi Companion stays out of the signal path.

## Phases

Each phase is its own PR; `audio-path-reviewer` reviews R2 and R4, and `eq-window-reviewer` reviews any EQ window change.

1. **R1 — EQ core.** Extract `PEQDocument` (bands, headroom, undo, profiles) from `AppModel` with unit tests. No behavior change.
2. **R2 — Output and equalizer.**
   - Output follow plus preferred device.
   - Core Audio listeners (default output, device list, alive, rate, hog mode) and sleep/wake, replacing the 0.4 s poll.
   - Tap re-targeting; exclusive-player suspend/resume.
   - Equalizer switch replaces Pass-through.
   - Remove the pin list and BlackHole-era code; no main-thread waits on the audio queue.
   - Mert re-runs the hot-plug and sleep tests.
3. **R3 — Per-device profiles** with versioned storage (A7).
4. **R4 — Apple Music Mode** switch and the signal path model (sources, formats, dot state).
5. **R5 — Menu panel, Settings window, launch at login, first run.**

## Later (not in 0.3)

- AutoEQ `ParametricEQ.txt` import and export, designed together with the EQ window rework.
- Auto EQ (Mert holds the details).

## Dropped

Global EQ hotkey; device-centric "cards" (switching gear should not force choices — the follow / preferred-device model already handles it).
