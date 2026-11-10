#!/bin/bash
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
lock_file="$root/engine/engine.lock.json"
update_lock=0

if [[ $# -gt 1 ]]; then
    echo "usage: $0 [--update-lock]" >&2
    exit 2
fi
if [[ ${1:-} == "--update-lock" ]]; then
    update_lock=1
elif [[ $# -eq 1 ]]; then
    echo "usage: $0 [--update-lock]" >&2
    exit 2
fi

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
updated_lock="$work/engine.lock.json"
cp "$lock_file" "$updated_lock"
vendor="$root/Vendor/engine"
mkdir -p "$vendor"

platforms="$(python3 -I - "$lock_file" <<'PY'
import json
import sys

with open(sys.argv[1], encoding="utf-8") as handle:
    print("\n".join(json.load(handle)["platforms"]))
PY
)"

for platform in $platforms; do
    tarball="$(python3 -I - "$lock_file" "$platform" <<'PY'
import json
import sys

with open(sys.argv[1], encoding="utf-8") as handle:
    print(json.load(handle)["platforms"][sys.argv[2]]["tarball"])
PY
)"
    expected="$(python3 -I - "$lock_file" "$platform" <<'PY'
import json
import sys

with open(sys.argv[1], encoding="utf-8") as handle:
    print(json.load(handle)["platforms"][sys.argv[2]]["sha256"])
PY
)"
    archive="$work/$platform.tgz"
    curl --fail --location --silent --show-error "$tarball" --output "$archive"
    actual="$(shasum -a 256 "$archive" | awk '{print $1}')"

    if [[ $update_lock -eq 1 ]]; then
        python3 -I - "$updated_lock" "$platform" "$actual" <<'PY'
import json
import sys

path, platform, checksum = sys.argv[1:]
with open(path, encoding="utf-8") as handle:
    lock = json.load(handle)
lock["platforms"][platform]["sha256"] = checksum
with open(path, "w", encoding="utf-8") as handle:
    json.dump(lock, handle, indent=2)
    handle.write("\n")
PY
    elif [[ "$expected" == "TBD" ]]; then
        echo "$platform checksum is TBD; rerun with --update-lock to record $actual" >&2
        exit 1
    else
        printf '%s  %s\n' "$expected" "$archive" | shasum -a 256 -c - >/dev/null
    fi

    extracted="$work/$platform"
    mkdir -p "$extracted" "$vendor/$platform"
    tar -xzf "$archive" -C "$extracted"
    if [[ -f "$extracted/package/bin/tokscale" ]]; then
        binary="$extracted/package/bin/tokscale"
    elif [[ -f "$extracted/bin/tokscale" ]]; then
        binary="$extracted/bin/tokscale"
    else
        echo "$platform archive does not contain bin/tokscale" >&2
        exit 1
    fi
    cp "$binary" "$vendor/$platform/tokscale"
    chmod 755 "$vendor/$platform/tokscale"
done

lipo -create \
    "$vendor/darwin-arm64/tokscale" \
    "$vendor/darwin-x64/tokscale" \
    -output "$work/tokscale"
cp "$work/tokscale" "$vendor/tokscale"
chmod 755 "$vendor/tokscale"

if [[ $update_lock -eq 1 ]]; then
    cp "$updated_lock" "$lock_file"
fi
