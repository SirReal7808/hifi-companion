---
name: install
description: Build HiFi Companion (Release), install it to ~/Applications/HiFiCompanion.app, launch it and verify the launch stamp; optionally capture the EQ window for a visual check. Use whenever a build must be installed for Mert to try, or to check the EQ window still matches the approved layout.
---

# Install HiFi Companion

Run from the repo root. Stop and report on the first failure.

1. If `project.yml` changed on this branch: `xcodegen generate`.
2. Build:
   ```bash
   xcodebuild -scheme "HiFi Companion" -configuration Release -derivedDataPath build build 2>&1 | grep -E "error:|BUILD (SUCCEEDED|FAILED)"
   ```
3. Install and launch (quitting a running copy is fine; say so in the reply):
   ```bash
   pkill -x HiFiCompanion 2>/dev/null || true
   mkdir -p ~/Applications
   rm -rf ~/Applications/HiFiCompanion.app
   ditto build/Build/Products/Release/HiFiCompanion.app ~/Applications/HiFiCompanion.app
   open ~/Applications/HiFiCompanion.app
   ```
4. Verify: `pgrep -lx HiFiCompanion` runs from `~/Applications/…`, and the installed `Info.plist` shows the expected `CFBundleShortVersionString` / `CFBundleVersion` (`/usr/libexec/PlistBuddy -c 'Print CFBundleVersion' ~/Applications/HiFiCompanion.app/Contents/Info.plist`).

Never install over `~/Applications/HiFiCompanion-0.*.app` (release archives).

## Optional: EQ visual check

Use when `PEQView.swift` / `PEQPanelController.swift` changed. It runs a second app instance against the real DAC for 10 s — **skip it if Mert may be listening** (ask), and never start Music or YouTube.

```bash
SHOT="<scratchpad>/eq-check.jpg"
perl -e 'alarm shift; exec @ARGV' 10 build/Build/Products/Release/HiFiCompanion.app/Contents/MacOS/HiFiCompanion --show-eq --eq-unlock-controls --eq-screenshot "$SHOT" 2>/dev/null | grep -E "launch stamp|EQ_OPEN|EQ_SHOT"
# The killed instance leaves its `log stream` child orphaned (PPID 1): kill only those.
ps -axo pid,ppid,command | awk '$2==1 && /\/usr\/bin\/log stream/ {print $1}' | xargs -r kill
```

Pass criteria: `EQ_OPEN` shows `frame == expect`; the screenshot matches `docs/media/eq-v0.2-dark.jpg` (no footer strip, equal pad above/below Add Band / Reset, side glass corners and shadow unclipped). Report what differs; do not "fix" the layout without reading `docs/eq-window.md`.
