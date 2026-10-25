# HiFi Companion

macOS menu-bar app that matches your pinned external DAC’s sample rate and bit depth to the track currently playing in Apple Music. Phase 1 replaces [LosslessSwitcher](https://github.com/vincentneo/LosslessSwitcher) for format matching only (no PEQ, sweep, or virtual device).

**Requirements:** macOS 14+, Xcode 15+, Apple Music. Not sandboxed and not intended for the Mac App Store (`log stream` needs unsandboxed access).

## Apple Music mode

Apple Music mode switches the pinned DAC **only while Music is the sole app sending audio to that device**.

- Music alone → match sample rate / bit depth as usual.
- Any other audible client on the same DAC (for example a browser playing YouTube) → **lock**: keep the current format; ignore new track-format applies until unlocked. The menu bar shows **Locked**, and the menu says other audio is present.
- When those other clients stop and Music is alone again → **unlock** and catch up to the current track format if needed.
- Silent apps that are merely open do not lock. Short system / notification chirps are softened with a brief grace period and an ignore list for obvious system UI sound sources.

## Honest limits (reclocking)

- Sample-rate changes make the DAC reclock. At track starts that coincide with a rate change, brief dropouts or silence are normal.
- Some DACs click or pop on reclock; that is hardware behavior, not something software can fully remove while sharing Core Audio with the rest of the system.
- Other apps on the same DAC (for example YouTube) would glitch or freeze briefly if a switch were allowed while they play. With the exclusive-Music lock, switches are skipped while they are audible.

## Build in Xcode

1. Open `HiFiCompanion.xcodeproj`.
2. Select the **HiFi Companion** scheme and **My Mac**.
3. Signing: choose your Team under Signing & Capabilities (or use ad-hoc / Sign to Run Locally).
4. Product → Build (⌘B), then Product → Run (⌘R).

Command line:

```bash
xcodegen generate   # only if project.yml changed
xcodebuild -scheme "HiFi Companion" -configuration Release -derivedDataPath build
open "build/Build/Products/Release/HiFiCompanion.app"
```

## Run the app

- The app is a menu-bar agent (`LSUIElement`): no Dock icon and no main window.
- Look for a status item titled with the active DAC format (for example `96 kHz / 24-bit`), `Locked` when other audio is on the DAC, or `HiFi` before a format is known.
- Click the status item for the menu.

Quit from the menu (**Quit HiFi Companion**) or with ⌘Q while the menu is focused.

## Pin the DAC

1. Connect the external DAC and select it in **System Settings → Sound** if you want it as the system default as well.
2. Open the HiFi Companion menu.
3. Under the device list, click your DAC so it shows a checkmark. That pin is remembered.
4. Choose **System Default** to follow macOS’s default output instead of a pinned UID.

The menu shows:

- A short note that Apple Music mode switches only while Music is alone on the device.
- **Matching** status — Music alone, or locked because other audio is present.
- **Track** — format detected from Apple Music (`log stream`, with AppleScript sample-rate fallback).
- **DAC** — current nominal rate / physical bit depth on the pinned (or default) device.

## Test with Apple Music

1. In Music: turn **Sound Check** off, turn **EQ** off, and avoid Spatial / Atmos for the switcher test (stereo Lossless / Hi-Res Lossless).
2. Set Music volume to **100%** (system volume can stay comfortable).
3. Open **Audio MIDI Setup** (Applications → Utilities) and select the same DAC.
4. Start HiFi Companion, pin that DAC, then play a Lossless track (for example 44.1 kHz / 16-bit).
5. In Audio MIDI Setup, confirm Format matches what the menu reports (16-bit may appear as 24-bit on DACs that only advertise 24-bit containers — that is intentional zero-padding, not downconversion).
6. Switch to a Hi-Res track (96 kHz or 192 kHz). Confirm the status item and Audio MIDI Setup update to that rate without forcing an unsupported rate.
7. With Music playing, start YouTube (or another audible app) on the same DAC. Matching should show **Locked** and further Music rate changes should not move the DAC.
8. Stop the other app. Matching should unlock and catch up to the current Music track format.

Detection watches `/usr/bin/log stream` for `com.apple.coreaudio`, `com.apple.coremedia`, and Music `audioCapabilities` lines (ALAC input format, `asbdSampleRate`, `sdBitDepth`). If logs are quiet, AppleScript’s `sample rate of current track` is used as a fallback for rate only.

After each apply, a short settle window ignores lower-confidence or older detections (especially after an upswitch to a higher rate). ALAC input format outranks AudioQueue / `audioCapabilities`. Music track-change notifications allow a legitimate high-priority downgrade during settle so 96 → 44.1 still works when you change tracks.

## Phase 1 scope

Included: menu-bar status item, device pin, Music format detection, Core Audio rate / physical format switching, exclusive-Music lock while other audio uses the DAC.

Out of scope for this phase: PEQ, sine sweep, virtual audio device, settings window, Fixed mode UI.
