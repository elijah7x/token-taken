#!/usr/bin/env python3
"""Generate a schema-v1 updates.json feed for a notarized Token Taken DMG."""

import argparse
import hashlib
import json
import re
import sys
from datetime import datetime, timezone
from pathlib import Path
from urllib.parse import urlparse


DOTTED_NUMERIC_RE = re.compile(r"\A[0-9]+(?:\.[0-9]+)*\Z")


def parse_args(argv):
    parser = argparse.ArgumentParser(
        description="Write a schema-v1 update feed JSON for a Token Taken DMG."
    )
    parser.add_argument("--dmg", required=True, help="Path to the DMG file.")
    parser.add_argument("--version", required=True, help="Marketing version string.")
    parser.add_argument("--build", required=True, help="Build number string.")
    parser.add_argument(
        "--base-url",
        required=True,
        help="HTTPS directory URL the DMG will be served from.",
    )
    parser.add_argument(
        "--notes-file",
        default=None,
        help="Optional path to Markdown release notes.",
    )
    parser.add_argument(
        "--minimum-system-version",
        default="26.0",
        help="Minimum supported macOS version (default: 26.0).",
    )
    parser.add_argument("--output", required=True, help="Output JSON file path.")
    return parser.parse_args(argv)


def sha256_and_size(path):
    digest = hashlib.sha256()
    size = 0
    with path.open("rb") as handle:
        while True:
            chunk = handle.read(1024 * 1024)
            if not chunk:
                break
            digest.update(chunk)
            size += len(chunk)
    return digest.hexdigest().lower(), size


def main(argv):
    args = parse_args(argv)

    base_url = args.base_url.strip()
    parsed = urlparse(base_url)
    if parsed.scheme.lower() != "https" or not parsed.netloc:
        print(
            "error: --base-url must be an https URL with a host: %s" % base_url,
            file=sys.stderr,
        )
        return 2

    dmg_path = Path(args.dmg)
    if not dmg_path.is_file():
        print("error: DMG not found: %s" % dmg_path, file=sys.stderr)
        return 1

    version = args.version.strip()
    build = args.build.strip()
    minimum_system_version = args.minimum_system_version.strip()
    for flag, value in (
        ("--version", version),
        ("--build", build),
        ("--minimum-system-version", minimum_system_version),
    ):
        if not DOTTED_NUMERIC_RE.fullmatch(value):
            print(
                "error: %s must be dotted numeric (e.g. 1.2.3): %s" % (flag, value),
                file=sys.stderr,
            )
            return 2

    notes = ""
    if args.notes_file is not None:
        notes_path = Path(args.notes_file)
        if not notes_path.is_file():
            print("error: notes file not found: %s" % notes_path, file=sys.stderr)
            return 1
        notes = notes_path.read_text(encoding="utf-8")

    sha256, size = sha256_and_size(dmg_path)
    published_at = (
        datetime.now(timezone.utc)
        .replace(microsecond=0)
        .isoformat()
        .replace("+00:00", "Z")
    )
    download_url = base_url.rstrip("/") + "/" + dmg_path.name

    payload = {
        "schema_version": 1,
        "version": version,
        "build": build,
        "minimum_system_version": minimum_system_version,
        "download_url": download_url,
        "sha256": sha256,
        "size": size,
        "notes": notes,
        "published_at": published_at,
    }

    output_path = Path(args.output)
    output_path.parent.mkdir(parents=True, exist_ok=True)
    output_path.write_text(
        json.dumps(payload, indent=2, ensure_ascii=False) + "\n",
        encoding="utf-8",
    )
    print(output_path)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
