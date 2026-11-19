#!/bin/bash
# Regenerates the README media in docs/media/: eq-v0.5-dark.jpg, eq-v0.5-light.jpg and
# sweep-fix-peak.gif. Uses the Release build in build.noindex/ (build it first).
# The demo loads its own curve and presses FIX PEAK, which the app saves like a user edit,
# so this script quits the running app, backs up its defaults, and restores them at the end.
# No tone plays (the sweep needle is drawn without the bridge). Needs ffmpeg.
set -uo pipefail
cd "$(dirname "$0")/.."
BIN="build.noindex/Build/Products/Release/HiFiCompanion.app/Contents/MacOS/HiFiCompanion"
INSTALLED="$HOME/Applications/HiFiCompanion.app"
DOMAIN="com.hificompanion.app"
[ -x "$BIN" ] || { echo "Build Release first: $BIN"; exit 2; }
command -v ffmpeg >/dev/null || { echo "ffmpeg missing (brew install ffmpeg)"; exit 2; }

WORK="$(mktemp -d -t hifi-media)"
was_running=0
pgrep -x HiFiCompanion >/dev/null && was_running=1
pkill -x HiFiCompanion 2>/dev/null && sleep 1
defaults export "$DOMAIN" "$WORK/defaults.plist" || { echo "defaults backup failed"; exit 1; }

finish() {
    pkill -f "build.noindex/.*HiFiCompanion" 2>/dev/null
    defaults import "$DOMAIN" "$WORK/defaults.plist" && echo "Defaults restored."
    [ "$was_running" = 1 ] && [ -d "$INSTALLED" ] && open "$INSTALLED"
    rm -rf "$WORK"
}
trap finish EXIT
trap 'exit 130' INT TERM

# Demo first: the screenshots then show the same curve with the FIX PEAK band.
timeout 90 "$BIN" --show-eq --eq-unlock-controls --eq-demo-frames "$WORK/frames" | grep EQ_DEMO

shot() { # appearance, output
    "$BIN" --show-eq --eq-unlock-controls --eq-appearance "$1" --eq-screenshot "$WORK/$1.jpg" | grep -m1 EQ_SHOT &
    sleep 5
    pkill -f "build.noindex/.*HiFiCompanion"
    wait
    sips -s format jpeg -s formatOptions 82 "$WORK/$1.jpg" --out "$2" >/dev/null
}
shot dark docs/media/eq-v0.5-dark.jpg
shot light docs/media/eq-v0.5-light.jpg

ffmpeg -loglevel error -y -framerate 25 -i "$WORK/frames/frame-%04d.jpg" \
    -vf "scale=720:-1:flags=lanczos,split[a][b];[a]palettegen=max_colors=192:stats_mode=diff[p];[b][p]paletteuse=dither=sierra2_4a:diff_mode=rectangle" \
    -loop 0 docs/media/sweep-fix-peak.gif
ls -la docs/media/eq-v0.5-*.jpg docs/media/sweep-fix-peak.gif
