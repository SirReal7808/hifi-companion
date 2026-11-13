#!/bin/bash
# Xcode build phase: re-sign Sparkle's nested helpers with our Developer ID.
# Xcode signs the embedded Sparkle.framework but leaves Autoupdate, Updater.app and the
# XPC services ad-hoc, which notarization rejects. Order: innermost first, then the framework;
# Xcode signs the app itself after this phase. Debug builds (ad-hoc "-") are left alone.
set -euo pipefail

identity="${EXPANDED_CODE_SIGN_IDENTITY:-}"
if [[ -z "$identity" || "$identity" == "-" ]]; then
    echo "sign-sparkle-helpers: ad-hoc build, skipping"
    exit 0
fi

framework="${TARGET_BUILD_DIR}/${FRAMEWORKS_FOLDER_PATH}/Sparkle.framework"
current="$framework/Versions/B"
sign=(codesign --force --sign "$identity" --options runtime --timestamp)

for xpc in "$current"/XPCServices/*.xpc; do
    [[ -e "$xpc" ]] || continue
    "${sign[@]}" --preserve-metadata=entitlements "$xpc"
done
"${sign[@]}" "$current/Autoupdate"
"${sign[@]}" "$current/Updater.app"
"${sign[@]}" "$framework"
