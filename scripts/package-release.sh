#!/bin/bash
# Package an approved HiFi Companion build for public download:
#   app → notarize + staple → signed .dmg → notarize + staple → appcast.xml (Sparkle).
# Output goes to the releases folder (default ~/Library/Application Support/HiFiCompanion/Releases),
# which keeps every shipped .dmg and the growing appcast.xml. /release uploads the new .dmg and
# appcast.xml to the GitHub Release; nothing here publishes anything.
#
# Usage: scripts/package-release.sh <version> [--app <path>] [--notes <file.md>] [--out <dir>] [--skip-notarize]
#   --skip-notarize  dry run for testing the pipeline (the result is NOT fit to ship)
#
# Notarization needs the keychain profile "HiFiCompanion-notary" (docs/releases.md#notarization).
set -euo pipefail

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
profile="HiFiCompanion-notary"
repo_url="https://github.com/SirReal7808/hifi-companion"
team_id="3R38CGHB29"
sparkle_bin="$repo_root/build.noindex/SourcePackages/artifacts/sparkle/Sparkle/bin"

version=""
app="$HOME/Applications/HiFiCompanion.app"
notes=""
out="$HOME/Library/Application Support/HiFiCompanion/Releases"
notarize=1

while [[ $# -gt 0 ]]; do
    case "$1" in
        --app) app="$2"; shift 2 ;;
        --notes) notes="$2"; shift 2 ;;
        --out) out="$2"; shift 2 ;;
        --skip-notarize) notarize=0; shift ;;
        -*) echo "unknown option: $1" >&2; exit 2 ;;
        *) version="$1"; shift ;;
    esac
done
[[ -n "$version" ]] || { echo "usage: $0 <version> [--app path] [--notes file.md] [--out dir] [--skip-notarize]" >&2; exit 2; }

step() { printf '\n==> %s\n' "$*"; }
fail() { echo "error: $*" >&2; exit 1; }

# 1. The app is the approved build, signed with our Developer ID and hardened runtime.
step "Checking $app"
[[ -d "$app" ]] || fail "no app at $app"
app_version=$(defaults read "$app/Contents/Info.plist" CFBundleShortVersionString)
app_build=$(defaults read "$app/Contents/Info.plist" CFBundleVersion)
[[ "$app_version" == "$version" ]] || fail "app is $app_version (build $app_build), expected $version"
codesign --verify --deep --strict "$app" || fail "codesign verification failed"
sig=$(codesign -dvv "$app" 2>&1)
grep -q "Authority=Developer ID Application: .*($team_id)" <<<"$sig" || fail "not signed with the Developer ID ($team_id)"
grep -q "flags=.*runtime" <<<"$sig" || fail "hardened runtime is off"
grep -q "^Timestamp=" <<<"$sig" || fail "signature has no secure timestamp"
codesign -d --entitlements - "$app" 2>/dev/null | grep -q "get-task-allow" \
    && fail "app has the get-task-allow entitlement (notarization rejects it)"
[[ -x "$sparkle_bin/generate_appcast" ]] || fail "Sparkle tools missing; build the app once (xcodebuild) to fetch the package"
if (( notarize )); then
    xcrun notarytool history --keychain-profile "$profile" >/dev/null 2>&1 \
        || fail "keychain profile '$profile' missing; see docs/releases.md#notarization"
fi
echo "HiFi Companion $app_version (build $app_build)"

work=$(mktemp -d -t hifi-release)
trap 'rm -rf "$work"' EXIT
staged="$work/stage/HiFiCompanion.app"
mkdir -p "$work/stage"
ditto "$app" "$staged"

submit() {  # notarize one file and fail with Apple's log on rejection
    local file="$1" result id
    result=$(xcrun notarytool submit "$file" --keychain-profile "$profile" --wait --output-format json) || true
    echo "$result"
    id=$(plutil -extract id raw - <<<"$result" 2>/dev/null || true)
    if ! grep -q '"status" *: *"Accepted"' <<<"$result"; then
        [[ -n "$id" ]] && xcrun notarytool log "$id" --keychain-profile "$profile" || true
        fail "notarization of $(basename "$file") was not accepted"
    fi
}

# 2. Notarize the app itself and staple it, so a copy dragged out of the dmg passes Gatekeeper offline.
if (( notarize )); then
    step "Notarizing the app"
    ditto -c -k --keepParent "$staged" "$work/app.zip"
    submit "$work/app.zip"
    xcrun stapler staple "$staged"
    xcrun stapler validate "$staged"
fi

# 3. Build the dmg (app + Applications link), sign it, notarize and staple it.
step "Building the dmg"
dmg_name="HiFiCompanion-$version.dmg"
dmg="$work/$dmg_name"
ln -s /Applications "$work/stage/Applications"
hdiutil create -volname "HiFi Companion" -srcfolder "$work/stage" -fs HFS+ -format UDZO -ov "$dmg" >/dev/null
codesign --force --sign "Developer ID Application: Mert Lafci ($team_id)" --timestamp "$dmg"
if (( notarize )); then
    step "Notarizing the dmg"
    submit "$dmg"
    xcrun stapler staple "$dmg"
    xcrun stapler validate "$dmg"
    spctl --assess --type open --context context:primary-signature -v "$dmg" || fail "Gatekeeper rejects the dmg"
fi

# 4. Add the dmg to the releases folder and regenerate appcast.xml (signed with the EdDSA key in the keychain).
step "Updating appcast.xml in $out"
mkdir -p "$out"
[[ -e "$out/$dmg_name" ]] && fail "$out/$dmg_name already exists; a shipped version is never repackaged"
cp "$dmg" "$out/$dmg_name"
if [[ -n "$notes" ]]; then
    cp "$notes" "$out/HiFiCompanion-$version.md"
fi
"$sparkle_bin/generate_appcast" \
    --download-url-prefix "$repo_url/releases/download/v$version/" \
    --link "$repo_url" \
    --embed-release-notes \
    --maximum-deltas 0 \
    "$out"

step "Done"
echo "dmg:     $out/$dmg_name"
echo "appcast: $out/appcast.xml"
(( notarize )) || echo "DRY RUN: not notarized, do not upload"
