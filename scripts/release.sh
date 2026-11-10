#!/bin/bash
set -euo pipefail

usage() {
    echo "usage: TOKEN_TAKEN_TEAM_ID=<team> NOTARY_PROFILE=<profile> $0 all [--no-wait]" >&2
    exit 2
}

if [[ $# -lt 1 || $# -gt 2 ]]; then
    usage
fi
if [[ "$1" != "all" ]]; then
    usage
fi
wait_for_notarization=1
if [[ ${2:-} == "--no-wait" ]]; then
    wait_for_notarization=0
elif [[ $# -eq 2 ]]; then
    usage
fi

team_id="${TOKEN_TAKEN_TEAM_ID:-}"
profile="${NOTARY_PROFILE:-}"
if [[ -z "$team_id" || -z "$profile" ]]; then
    usage
fi
identity="${TOKEN_TAKEN_SIGNING_IDENTITY:-Developer ID Application}"
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"

for tool in xcodegen xcodebuild codesign diskutil xcrun; do
    if ! command -v "$tool" >/dev/null 2>&1; then
        echo "$tool is required" >&2
        exit 1
    fi
done

if [[ -n "${TOKEN_TAKEN_ARTIFACTS_ROOT:-}" ]]; then
    case "$TOKEN_TAKEN_ARTIFACTS_ROOT" in
        /*) artifacts="$TOKEN_TAKEN_ARTIFACTS_ROOT" ;;
        *) echo "TOKEN_TAKEN_ARTIFACTS_ROOT must be an absolute path" >&2; exit 1 ;;
    esac
else
    common_dir="$(git -C "$root" rev-parse --path-format=absolute --git-common-dir)"
    common_dir="$(cd "$common_dir" && pwd -P)"
    checkout="$(dirname "$common_dir")"
    artifacts="$(dirname "$checkout")"
fi
mkdir -p "$artifacts"
artifacts="$(cd "$artifacts" && pwd -P)"
case "$artifacts/" in
    "$root/"*) echo "Release artifacts must be outside the source tree" >&2; exit 1 ;;
esac

version="$(awk '/MARKETING_VERSION:/ { gsub(/"/, "", $2); print $2; exit }' "$root/project.yml")"
build_number="$(awk '/CURRENT_PROJECT_VERSION:/ { gsub(/"/, "", $2); print $2; exit }' "$root/project.yml")"
if [[ -z "$version" || -z "$build_number" ]]; then
    echo "Could not read the version from project.yml" >&2
    exit 1
fi

release_dir="$artifacts/local-packages/token-taken/$version-$build_number"
derived_data="$release_dir/DerivedData"
stage="$release_dir/DMG"
dmg="$artifacts/local-packages/TokenTaken-$version-$build_number.dmg"
mkdir -p "$release_dir"

"$root/scripts/fetch-engine.sh"
(cd "$root" && xcodegen generate)
xcodebuild \
    -project "$root/TokenTaken.xcodeproj" \
    -scheme TokenTaken \
    -configuration Release \
    -derivedDataPath "$derived_data" \
    ARCHS="arm64 x86_64" \
    ONLY_ACTIVE_ARCH=NO \
    DEVELOPMENT_TEAM="$team_id" \
    CODE_SIGN_IDENTITY="$identity" \
    CODE_SIGN_STYLE=Manual \
    CODE_SIGNING_ALLOWED=YES \
    CODE_SIGN_INJECT_BASE_ENTITLEMENTS=NO \
    ENABLE_HARDENED_RUNTIME=YES \
    build

app="$derived_data/Build/Products/Release/Token Taken.app"
framework="$app/Contents/Frameworks/TokenTakenKit.framework"
cli="$app/Contents/Helpers/token-taken"
tokscale="$app/Contents/Helpers/tokscale"
for product in "$app" "$framework" "$cli" "$tokscale"; do
    if [[ ! -e "$product" ]]; then
        echo "Missing release product: $product" >&2
        exit 1
    fi
done

codesign --force --options runtime --timestamp --sign "$identity" "$framework"
codesign --force --options runtime --timestamp \
    --entitlements "$root/TokenTakenCLI/TokenTakenCLI.entitlements" \
    --sign "$identity" "$cli"
codesign --force --options runtime --timestamp --sign "$identity" "$tokscale"
codesign --force --options runtime --timestamp \
    --entitlements "$root/TokenTaken/TokenTaken.entitlements" \
    --sign "$identity" "$app"

rm -rf "$stage"
mkdir -p "$stage"
ditto "$app" "$stage/Token Taken.app"
ln -s /Applications "$stage/Applications"
rm -f "$dmg"
diskutil image create from --format UDZO --volumeName "Token Taken" "$stage" "$dmg"

if [[ $wait_for_notarization -eq 1 ]]; then
    xcrun notarytool submit "$dmg" --keychain-profile "$profile" --wait
    xcrun stapler staple "$dmg"
else
    xcrun notarytool submit "$dmg" --keychain-profile "$profile" --no-wait
    echo "Notarization was submitted without waiting. After acceptance, run: xcrun stapler staple \"$dmg\""
fi

echo "Release artifact: $dmg"
