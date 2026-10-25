# HiFi Companion

macOS menu-bar app that matches your pinned external DAC’s sample rate and bit depth to the track currently playing in Apple Music. Phase 1 replaces [LosslessSwitcher](https://github.com/vincentneo/LosslessSwitcher) for format matching only (no PEQ, sweep, or virtual device).

**Requirements:** macOS 14+, Xcode 15+, Apple Music. Not sandboxed and not intended for the Mac App Store (`log stream` needs unsandboxed access).

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
- Look for a status item titled with the active DAC format (for example `96 kHz / 24-bit`), or `HiFi` before a format is known.
- Click the status item for the menu.

Quit from the menu (**Quit HiFi Companion**) or with ⌘Q while the menu is focused.

## Pin the DAC

1. Connect the external DAC and select it in **System Settings → Sound** if you want it as the system default as well.
2. Open the HiFi Companion menu.
3. Under the device list, click your DAC so it shows a checkmark. That pin is remembered.
4. Choose **System Default** to follow macOS’s default output instead of a pinned UID.

The menu shows:

- **Track** — format detected from Apple Music (`log stream`, with AppleScript sample-rate fallback).
- **DAC** — current nominal rate / physical bit depth on the pinned (or default) device.

## Test with Apple Music

1. In Music: turn **Sound Check** off, turn **EQ** off, and avoid Spatial / Atmos for the switcher test (stereo Lossless / Hi-Res Lossless).
2. Set Music volume to **100%** (system volume can stay comfortable).
3. Open **Audio MIDI Setup** (Applications → Utilities) and select the same DAC.
4. Start HiFi Companion, pin that DAC, then play a Lossless track (for example 44.1 kHz / 16-bit).
5. In Audio MIDI Setup, confirm Format matches what the menu reports (16-bit may appear as 24-bit on DACs that only advertise 24-bit containers — that is intentional zero-padding, not downconversion).
6. Switch to a Hi-Res track (96 kHz or 192 kHz). Confirm the status item and Audio MIDI Setup update to that rate without forcing an unsupported rate.

Detection watches `/usr/bin/log stream` for `com.apple.coreaudio`, `com.apple.coremedia`, and Music `audioCapabilities` lines (ALAC input format, `asbdSampleRate`, `sdBitDepth`). If logs are quiet, AppleScript’s `sample rate of current track` is used as a fallback for rate only.

## Phase 1 scope

Included: menu-bar status item, device pin, Music format detection, Core Audio rate / physical format switching.

Out of scope for this phase: PEQ, sine sweep, virtual audio device, settings window.
