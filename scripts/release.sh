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
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"

for tool in python3 xcodegen xcodebuild codesign security diskutil lipo xcrun; do
    if ! command -v "$tool" >/dev/null 2>&1; then
        echo "$tool is required" >&2
        exit 1
    fi
done

if [[ -n "${TOKEN_TAKEN_SIGNING_IDENTITY:-}" ]]; then
    identity="$TOKEN_TAKEN_SIGNING_IDENTITY"
else
    identities_output="$(security find-identity -v -p codesigning)"
    identity="$(python3 - "$team_id" "$identities_output" <<'PY'
import re
import sys

team_id = sys.argv[1]
output = sys.argv[2]
pattern = re.compile(
    r'^\s*\d+\)\s+([0-9A-Fa-f]{40})\s+"Developer ID Application:.*\('
    + re.escape(team_id)
    + r'\)"\s*$'
)
matches = []
for line in output.splitlines():
    match = pattern.match(line)
    if match:
        matches.append((match.group(1).upper(), line.strip()))

if len(matches) == 0:
    sys.stderr.write(f"No valid 'Developer ID Application' identity found for team {team_id}\n")
    sys.exit(1)
if len(matches) > 1:
    sys.stderr.write(
        f"Multiple 'Developer ID Application' identities found for team {team_id}; "
        "set TOKEN_TAKEN_SIGNING_IDENTITY explicitly:\n"
    )
    for _, line in matches:
        sys.stderr.write(f"  {line}\n")
    sys.exit(1)

print(matches[0][0])
PY
)"
fi

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
cli_version="$(python3 - "$root/TokenTakenCLI/main.swift" <<'PY'
import re
import sys

with open(sys.argv[1], encoding="utf-8") as handle:
    text = handle.read()
match = re.search(r'^\s*static\s+let\s+version\s*=\s*"([^"]+)"', text, re.MULTILINE)
if match:
    print(match.group(1))
PY
)"
if [[ -z "$cli_version" ]]; then
    echo "Could not read CLI version from TokenTakenCLI/main.swift" >&2
    exit 1
fi
if [[ "$cli_version" != "$version" ]]; then
    echo "TokenTakenCLI/main.swift version ($cli_version) differs from MARKETING_VERSION ($version)" >&2
    exit 1
fi

release_dir="$artifacts/local-packages/token-taken/$version-$build_number"
derived_data="$release_dir/DerivedData"
stage="$release_dir/DMG"
dmg="$artifacts/local-packages/TokenTaken-$version-$build_number.dmg"
mkdir -p "$release_dir"

"$root/scripts/fetch-engine.sh"
python3 "$root/scripts/update-prices.py" --check
(cd "$root" && xcodegen generate)
xcodebuild \
    -project "$root/TokenTaken.xcodeproj" \
    -scheme TokenTaken \
    -configuration Release \
    -derivedDataPath "$derived_data" \
    ARCHS="arm64" \
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

# The app ships for Apple silicon only (ADR-0012); a stray Intel slice doubles the download.
for binary in "$app/Contents/MacOS/Token Taken" "$framework/Versions/A/TokenTakenKit" "$cli" "$tokscale"; do
    archs="$(lipo -archs "$binary")"
    if [[ "$archs" != "arm64" ]]; then
        echo "$binary reports '$archs'; the release must be arm64 only" >&2
        exit 1
    fi
done

# Release binaries are stripped (project.yml); a stripped executable keeps no local
# symbol table, so a large `nm -a` dump means stripping did not run.
main_executable="$app/Contents/MacOS/Token Taken"
# Count defined symbols only (nm -U); imported symbols stay after stripping (about 1,700 today).
symbol_lines="$(nm -a -U "$main_executable" 2>/dev/null | wc -l | tr -d ' ')"
if [[ "$symbol_lines" -ge 200 ]]; then
    echo "$main_executable still defines $symbol_lines symbols; release binaries must be stripped" >&2
    exit 1
fi

# dSYMs stay beside the package so crash reports remain symbolicated after stripping.
products="$derived_data/Build/Products/Release"
mkdir -p "$release_dir/dSYMs"
dsym_count=0
for dsym in "$products"/*.dSYM; do
    if [[ -d "$dsym" ]]; then
        ditto "$dsym" "$release_dir/dSYMs/$(basename "$dsym")"
        dsym_count=$((dsym_count + 1))
    fi
done
if [[ "$dsym_count" -eq 0 ]]; then
    echo "No dSYMs found in $products; stripped release binaries need them for symbolication" >&2
    exit 1
fi

codesign --force --options runtime --timestamp --sign "$identity" "$framework"
codesign --force --options runtime --timestamp \
    --entitlements "$root/TokenTakenCLI/TokenTakenCLI.entitlements" \
    --sign "$identity" "$cli"
codesign --force --options runtime --timestamp --sign "$identity" "$tokscale"
codesign --force --options runtime --timestamp \
    --entitlements "$root/TokenTaken/TokenTaken.entitlements" \
    --sign "$identity" "$app"
codesign --verify --deep --strict "$app"

# The iCloud container entitlement is only valid together with this profile.
embedded_profile="$app/Contents/embedded.provisionprofile"
if [[ ! -f "$embedded_profile" ]]; then
    echo "Missing embedded Developer ID provisioning profile: $embedded_profile" >&2
    exit 1
fi
# A command-line PROVISIONING_PROFILE_SPECIFIER would apply to every target, so the
# profile name lives only on the app target in project.yml.
container="iCloud.io.github.elijah7x.TokenTaken"
entitlements_output="$(codesign -d --entitlements - "$app" 2>/dev/null)"
if [[ "$entitlements_output" != *"$container"* ]]; then
    echo "Signed app is missing the iCloud container entitlement: $container" >&2
    exit 1
fi
profile_output="$(security cms -D -i "$embedded_profile" 2>/dev/null)"
if [[ "$profile_output" != *"$container"* ]]; then
    echo "Embedded profile does not grant the iCloud container: $container" >&2
    exit 1
fi

app_kb="$(du -sk "$app" | awk '{print $1}')"
if [[ "$app_kb" -gt 102400 ]]; then
    echo "App bundle exceeds 100 MB limit (${app_kb} KB): $app" >&2
    exit 1
fi

rm -rf "$stage"
mkdir -p "$stage"
ditto "$app" "$stage/Token Taken.app"
cp "$root/LICENSE" "$stage/LICENSE"
cp "$root/THIRD_PARTY_NOTICES.md" "$stage/THIRD_PARTY_NOTICES.md"
ln -s /Applications "$stage/Applications"
rm -f "$dmg"
diskutil image create from --format ULMO --volumeName "Token Taken" "$stage" "$dmg"

feed="$release_dir/updates.json"
update_base_url="${TOKEN_TAKEN_UPDATE_BASE_URL:-https://elijah.ac.cn/token-taken/releases/v$version-$build_number}"
feed_args=(
    --dmg "$dmg"
    --version "$version"
    --build "$build_number"
    --base-url "$update_base_url"
    --output "$feed"
)
if [[ -n "${TOKEN_TAKEN_RELEASE_NOTES:-}" ]]; then
    feed_args+=(--notes-file "$TOKEN_TAKEN_RELEASE_NOTES")
fi

if [[ $wait_for_notarization -eq 1 ]]; then
    xcrun notarytool submit "$dmg" --keychain-profile "$profile" --wait
    xcrun stapler staple "$dmg"
    xcrun stapler validate "$dmg"

    feed_path="$(python3 "$root/scripts/make-update-feed.py" "${feed_args[@]}")"
    echo "Update feed: $feed_path"
else
    xcrun notarytool submit "$dmg" --keychain-profile "$profile" --no-wait
    echo "Notarization was submitted without waiting. After acceptance, run:"
    echo "  xcrun stapler staple \"$dmg\""
    echo "  xcrun stapler validate \"$dmg\""
    printf '  python3 %q' "$root/scripts/make-update-feed.py"
    printf ' %q' "${feed_args[@]}"
    printf '\n'
fi

echo "Release artifact: $dmg"
