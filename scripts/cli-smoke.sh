#!/usr/bin/env bash
# Smoke-tests a built token-taken binary against docs/contracts/cli.md.
# Usage: scripts/cli-smoke.sh /path/to/token-taken
set -euo pipefail

bin=${1:-}
if [ -z "$bin" ] || [ ! -x "$bin" ]; then
    printf 'usage: %s /path/to/token-taken\n' "${0##*/}" >&2
    exit 2
fi

python=/usr/bin/python3
sqlite=/usr/bin/sqlite3

support=$(mktemp -d "${TMPDIR:-/tmp}/token-taken-smoke-support.XXXXXX")
outputs=$(mktemp -d "${TMPDIR:-/tmp}/token-taken-smoke-out.XXXXXX")
trap 'rm -rf "$support" "$outputs"' EXIT

# The CLI reads $TOKEN_TAKEN_SUPPORT_DIR/usage.sqlite (TokenTakenKit/AppPaths.swift).
export TOKEN_TAKEN_SUPPORT_DIR="$support"
database="$support/usage.sqlite"

# Zone label for the seeded rows. The CLI parses it back per record, so it must be a real IANA id.
zone=$(readlink /etc/localtime 2>/dev/null | sed 's#.*/zoneinfo/##')
if [ -z "$zone" ]; then
    zone=${TZ:-UTC}
fi
today=$(TZ="$zone" date +%F)

failures=0
pass() { printf 'PASS %s\n' "$1"; }
fail() { printf 'FAIL %s: %s\n' "$1" "$2"; failures=$((failures + 1)); }

last_status=0
run() {
    local out=$1 err=$2
    shift 2
    last_status=0
    "$@" > "$out" 2> "$err" || last_status=$?
}

# The CLI opens the store read-only, so the script owns store creation. Schema matches
# TokenTakenKit/SQLiteUsageStore.swift (user_version 6).
create_store() {
    if [ -f "$database" ]; then
        return 0
    fi
    "$sqlite" "$database" <<'SQL'
CREATE TABLE IF NOT EXISTS devices (
    id TEXT PRIMARY KEY, name TEXT NOT NULL, last_seen REAL NOT NULL,
    kind TEXT NOT NULL DEFAULT 'mac'
);
CREATE TABLE IF NOT EXISTS health (
    source_id TEXT PRIMARY KEY, last_attempt REAL, last_success REAL,
    record_count INTEGER NOT NULL, error TEXT,
    skipped_records INTEGER NOT NULL DEFAULT 0, state TEXT NOT NULL DEFAULT 'stale'
);
CREATE TABLE IF NOT EXISTS daily_usage (
    device_id TEXT NOT NULL, source_id TEXT NOT NULL, model_id TEXT NOT NULL,
    raw_model_id TEXT NOT NULL, day TEXT NOT NULL, time_zone TEXT NOT NULL,
    input INTEGER NOT NULL, cache_read INTEGER NOT NULL, cache_write INTEGER NOT NULL,
    output INTEGER NOT NULL, reasoning INTEGER NOT NULL, uncategorized INTEGER NOT NULL,
    event_count INTEGER NOT NULL, cache_write_1h INTEGER NOT NULL DEFAULT 0,
    PRIMARY KEY (device_id, source_id, model_id, day)
);
CREATE TABLE IF NOT EXISTS hourly_usage (
    device_id TEXT NOT NULL, source_id TEXT NOT NULL, hour_start INTEGER NOT NULL,
    input INTEGER NOT NULL, cache_read INTEGER NOT NULL, cache_write INTEGER NOT NULL,
    output INTEGER NOT NULL, reasoning INTEGER NOT NULL, uncategorized INTEGER NOT NULL,
    event_count INTEGER NOT NULL, reasoning_known INTEGER NOT NULL,
    PRIMARY KEY (device_id, source_id, hour_start)
);
CREATE TABLE IF NOT EXISTS history_epochs (
    device_id TEXT NOT NULL, source_id TEXT NOT NULL, epoch TEXT NOT NULL,
    time_zone TEXT,
    PRIMARY KEY (device_id, source_id)
);
PRAGMA user_version = 6;
SQL
}

# (a) --schema exits 0 and prints the JSON schema version.
run "$outputs/schema.json" "$outputs/schema.err" "$bin" --schema
schema_status=$last_status
if [ "$schema_status" -eq 0 ] && "$python" -I -c '
import json, sys
doc = json.load(sys.stdin)
assert doc == 1, doc
' < "$outputs/schema.json"; then
    pass "a: --schema exits 0 with schema version 1"
else
    fail "a: --schema" "exit $schema_status"
fi

# (b) Usage errors exit 2.
run "$outputs/unknown.out" "$outputs/unknown.err" "$bin" not-a-command
unknown_status=$last_status
run "$outputs/period.out" "$outputs/period.err" "$bin" summary --period fortnight
period_status=$last_status
if [ "$unknown_status" -eq 2 ] && [ "$period_status" -eq 2 ]; then
    pass "b: unknown command and invalid --period exit 2"
else
    fail "b: usage errors" "unknown=$unknown_status invalid-period=$period_status"
fi

# (c) No store exits 3; an empty initialised store reports zero totals with a valid envelope.
# --local-only keeps every assertion independent of the runner's iCloud Drive contents.
run "$outputs/no-store.out" "$outputs/no-store.err" "$bin" summary --json --local-only --tz "$zone"
no_store_status=$last_status
create_store
run "$outputs/empty.json" "$outputs/empty.err" "$bin" summary --json --local-only --tz "$zone"
empty_status=$last_status
if [ "$no_store_status" -eq 3 ] && [ "$empty_status" -eq 0 ] && "$python" -I -c '
import json, sys
doc = json.load(sys.stdin)
assert doc["schemaVersion"] == 1, doc["schemaVersion"]
assert doc["generatedAt"].endswith("Z"), doc["generatedAt"]
assert isinstance(doc["timeZone"], str) and doc["timeZone"], doc["timeZone"]
total = doc["data"]["total"]
assert total == {"input": 0, "cacheRead": 0, "cacheWrite": 0, "output": 0,
                 "reasoning": 0, "uncategorized": 0, "total": 0}, total
assert doc["data"]["bySource"] == [] and doc["data"]["byModel"] == [], doc["data"]
assert doc["data"]["byDevice"] == [], doc["data"]
assert doc["data"]["cost"]["estimatedUSD"] == 0, doc["data"]["cost"]
assert doc["warnings"] == [], doc["warnings"]
' < "$outputs/empty.json"; then
    pass "c: missing store exits 3, empty store exits 0 with zero totals"
else
    fail "c: empty store" "no-store=$no_store_status empty=$empty_status"
fi

# (d) Seed two models for today and check summary, models, and CSV against the seeded sums.
"$sqlite" "$database" <<SQL
INSERT INTO daily_usage VALUES
    ('smoke-device', 'claude', 'smoke-model-a', 'smoke-model-a', '$today', '$zone', 100, 20, 10, 5, 3, 1, 4, 0),
    ('smoke-device', 'codex', 'smoke-model-b', 'smoke-model-b', '$today', '$zone', 7, 0, 0, 2, 0, 0, 1, 0);
SQL

run "$outputs/summary.json" "$outputs/summary.err" "$bin" summary --json --period week --local-only --tz "$zone"
summary_status=$last_status
if [ "$summary_status" -eq 0 ] && "$python" -I -c '
import json, sys
doc = json.load(sys.stdin)
today = sys.argv[1]
assert doc["schemaVersion"] == 1, doc["schemaVersion"]
assert doc["timeZone"] == sys.argv[2], doc["timeZone"]
assert doc["range"]["to"] == today, doc["range"]
assert isinstance(doc["range"]["from"], str), doc["range"]
total = doc["data"]["total"]
assert total == {"input": 107, "cacheRead": 20, "cacheWrite": 10, "output": 7,
                 "reasoning": 3, "uncategorized": 1, "total": 148}, total
assert doc["data"]["period"] == "week", doc["data"]["period"]
models = {m["id"]: m["total"] for m in doc["data"]["byModel"]}
assert models == {"smoke-model-a": 139, "smoke-model-b": 9}, models
' "$today" "$zone" < "$outputs/summary.json"; then
    pass "d1: summary --json --period week totals match the seeded rows"
else
    fail "d1: summary" "exit $summary_status"
fi

run "$outputs/models.json" "$outputs/models.err" "$bin" models --json --local-only --tz "$zone"
models_status=$last_status
if [ "$models_status" -eq 0 ] && "$python" -I -c '
import json, sys
doc = json.load(sys.stdin)
entries = doc["data"]["models"]
assert [e["id"] for e in entries] == ["smoke-model-a", "smoke-model-b"], entries
assert [e["total"] for e in entries] == [139, 9], entries
assert [e["rawModelIDs"] for e in entries] == [["smoke-model-a"], ["smoke-model-b"]], entries
assert entries[0]["input"] == 100 and entries[0]["output"] == 5, entries[0]
' < "$outputs/models.json"; then
    pass "d2: models --json lists both seeded models with their totals"
else
    fail "d2: models" "exit $models_status"
fi

run "$outputs/export.csv" "$outputs/export.err" "$bin" export --format csv --period all --local-only --tz "$zone"
export_status=$last_status
if [ "$export_status" -eq 0 ] && "$python" -I -c '
import csv, sys
path = sys.argv[1]
with open(path, "rb") as handle:
    raw = handle.read()
assert b"\r\n" in raw, "CSV must use CRLF line endings"
with open(path, newline="", encoding="utf-8") as handle:
    rows = list(csv.reader(handle))
header = ("day,timeZoneID,deviceID,sourceID,modelID,rawModelID,input,cacheRead,"
          "cacheWrite,output,reasoning,uncategorized,total,eventCount,cacheWrite1h").split(",")
assert rows[0] == header, rows[0]
assert len(rows) == 3, len(rows)
totals = {row[4]: int(row[12]) for row in rows[1:]}
assert totals == {"smoke-model-a": 139, "smoke-model-b": 9}, totals
' "$outputs/export.csv"; then
    pass "d3: export --format csv writes header plus both seeded rows"
else
    fail "d3: export --format csv" "exit $export_status"
fi

# (e) --local-only reads only the local store, with no synced-device root involved.
run "$outputs/local.json" "$outputs/local.err" "$bin" summary --json --period week --local-only --tz "$zone"
local_status=$last_status
if [ "$local_status" -eq 0 ] && "$python" -I -c '
import json, sys
doc = json.load(sys.stdin)
assert doc["schemaVersion"] == 1, doc["schemaVersion"]
assert doc["data"]["total"]["total"] == 148, doc["data"]["total"]
assert [d["id"] for d in doc["data"]["byDevice"]] == ["smoke-device"], doc["data"]["byDevice"]
assert "synthetic-data" not in [w["code"] for w in doc["warnings"]], doc["warnings"]
' < "$outputs/local.json"; then
    pass "e: --local-only reports the local store with sync never enabled"
else
    fail "e: --local-only" "exit $local_status"
fi

# (f) --version exits 0 and prints the CLI version string.
run "$outputs/version.out" "$outputs/version.err" "$bin" --version
version_status=$last_status
if [ "$version_status" -eq 0 ] && [ ! -s "$outputs/version.err" ] && "$python" -I -c '
import sys
parts = sys.stdin.read().strip().split()
assert len(parts) == 2 and parts[0] == "token-taken" and parts[1], parts
' < "$outputs/version.out"; then
    pass "f: --version exits 0 and prints the CLI version"
else
    fail "f: --version" "exit $version_status"
fi

# (g) An unknown flag exits 2 with usage text on stderr.
run "$outputs/unknown-flag.out" "$outputs/unknown-flag.err" "$bin" summary --json --unknown-flag
unknown_flag_status=$last_status
if [ "$unknown_flag_status" -eq 2 ] && [ ! -s "$outputs/unknown-flag.out" ] && "$python" -I -c '
import sys
err = sys.stdin.read()
assert "--unknown-flag" in err and "Usage:" in err, err
' < "$outputs/unknown-flag.err"; then
    pass "g: unknown flag exits 2 with usage on stderr"
else
    fail "g: unknown flag" "exit $unknown_flag_status"
fi

# Seed local device metadata and fresh source health for sources/devices checks.
now_epoch=$(date +%s)
"$sqlite" "$database" <<SQL
INSERT INTO devices VALUES ('smoke-device', 'Smoke Mac', $now_epoch.0, 'mac');
INSERT INTO health VALUES ('claude', $now_epoch.0, $now_epoch.0, 1, NULL, 0, 'ok');
SQL

# (h) sources --json reports seeded local source health with a null range.
run "$outputs/sources.json" "$outputs/sources.err" "$bin" sources --json --local-only --tz "$zone"
sources_status=$last_status
if [ "$sources_status" -eq 0 ] && "$python" -I -c '
import json, sys
doc = json.load(sys.stdin)
assert doc["schemaVersion"] == 1, doc["schemaVersion"]
assert doc["range"].get("from") is None and doc["range"].get("to") is None, doc["range"]
sources = doc["data"]["sources"]
assert len(sources) == 1, sources
entry = sources[0]
assert entry["id"] == "claude" and entry["state"] == "ok", entry
assert entry["records"] == 1 and entry["skippedRecords"] == 0 and entry.get("error") is None, entry
assert isinstance(entry["lastSuccess"], str) and entry["lastSuccess"].endswith("Z"), entry
' < "$outputs/sources.json"; then
    pass "h: sources --json reports seeded source health"
else
    fail "h: sources --json" "exit $sources_status"
fi

# (i) devices --json --local-only lists the local device and its token total.
run "$outputs/devices.json" "$outputs/devices.err" "$bin" devices --json --local-only --tz "$zone"
devices_status=$last_status
if [ "$devices_status" -eq 0 ] && "$python" -I -c '
import json, sys
doc = json.load(sys.stdin)
assert doc["schemaVersion"] == 1, doc["schemaVersion"]
devices = doc["data"]["devices"]
assert len(devices) == 1, devices
dev = devices[0]
assert dev["id"] == "smoke-device" and dev["name"] == "Smoke Mac", dev
assert dev["local"] is True and dev["total"] == 148, dev
assert dev.get("state") is None and dev.get("lastWrite") is None, dev
' < "$outputs/devices.json"; then
    pass "i: devices --json --local-only lists the local device and its total"
else
    fail "i: devices --json --local-only" "exit $devices_status"
fi

# (j) export: JSON envelope, default-range CSV, and --output file writing.
run "$outputs/export.json" "$outputs/export-json.err" "$bin" export --format json --local-only --tz "$zone"
export_json_status=$last_status
if [ "$export_json_status" -eq 0 ] && "$python" -I -c '
import json, sys
doc = json.load(sys.stdin)
today = sys.argv[1]
assert doc["schemaVersion"] == 1, doc["schemaVersion"]
assert doc["range"]["to"] == today, doc["range"]
rows = doc["data"]["rows"]
assert [(r["sourceID"], r["modelID"], r["total"]) for r in rows] == [
    ("claude", "smoke-model-a", 139),
    ("codex", "smoke-model-b", 9),
], rows
' "$today" < "$outputs/export.json"; then
    pass "j1: export --format json wraps daily rows in the standard envelope"
else
    fail "j1: export --format json" "exit $export_json_status"
fi

run "$outputs/export-month.csv" "$outputs/export-month.err" "$bin" export --format csv --local-only --tz "$zone"
export_csv_status=$last_status
if [ "$export_csv_status" -eq 0 ] && "$python" -I -c '
import csv, sys
path = sys.argv[1]
with open(path, "rb") as handle:
    raw = handle.read()
assert b"\r\n" in raw, "CSV must use CRLF line endings"
with open(path, newline="", encoding="utf-8") as handle:
    rows = list(csv.reader(handle))
assert len(rows) == 3 and rows[0][0] == "day", rows
assert {row[4]: int(row[12]) for row in rows[1:]} == {"smoke-model-a": 139, "smoke-model-b": 9}, rows
' "$outputs/export-month.csv"; then
    pass "j2: export --format csv writes default-range RFC 4180 CSV rows"
else
    fail "j2: export --format csv" "exit $export_csv_status"
fi

out_file="$outputs/written-export.json"
run "$outputs/export-out.stdout" "$outputs/export-out.err" "$bin" export --format json --output "$out_file" --local-only --tz "$zone"
export_out_status=$last_status
if [ "$export_out_status" -eq 0 ] && [ -s "$out_file" ] && [ ! -s "$outputs/export-out.stdout" ] && "$python" -I -c '
import json, sys
doc = json.load(sys.stdin)
assert doc["schemaVersion"] == 1, doc["schemaVersion"]
assert len(doc["data"]["rows"]) == 2, doc["data"]["rows"]
' < "$out_file"; then
    pass "j3: export --output writes a non-empty file and leaves stdout empty"
else
    fail "j3: export --output" "exit $export_out_status"
fi

# (k) An unwritable --output path exits 1 as documented in cli.md.
run "$outputs/unwritable.out" "$outputs/unwritable.err" "$bin" export --format json --output "$outputs/nonexistent-dir/x.json" --local-only --tz "$zone"
unwritable_status=$last_status
if [ "$unwritable_status" -eq 1 ] && [ ! -s "$outputs/unwritable.out" ] && "$python" -I -c '
import sys
err = sys.stdin.read()
assert "could not write output file" in err, err
' < "$outputs/unwritable.err"; then
    pass "k: unwritable --output path exits 1 with an error on stderr"
else
    fail "k: unwritable --output" "exit $unwritable_status"
fi

# Seed an earlier row on a second device so custom date ranges and device filters exclude real data.
"$sqlite" "$database" <<SQL
INSERT INTO daily_usage VALUES
    ('smoke-device-2', 'codex', 'smoke-model-b', 'smoke-model-b', '2025-06-15', '$zone', 30, 0, 0, 5, 0, 0, 2, 0);
SQL

# (l) --since/--until bounds custom ranges and clears the named period.
run "$outputs/range.json" "$outputs/range.err" "$bin" summary --json --since 2025-06-01 --until 2025-06-30 --local-only --tz "$zone"
range_status=$last_status
run "$outputs/range-today.json" "$outputs/range-today.err" "$bin" summary --json --since "$today" --until "$today" --local-only --tz "$zone"
range_today_status=$last_status
if [ "$range_status" -eq 0 ] && [ "$range_today_status" -eq 0 ] && "$python" -I -c '
import json, sys
past_path, today_path, today = sys.argv[1], sys.argv[2], sys.argv[3]
with open(past_path, encoding="utf-8") as handle:
    past = json.load(handle)
with open(today_path, encoding="utf-8") as handle:
    curr = json.load(handle)
assert past["range"] == {"from": "2025-06-01", "to": "2025-06-30"}, past["range"]
assert past["data"].get("period") is None, past["data"]
assert past["data"]["total"]["total"] == 35, past["data"]["total"]
assert curr["range"] == {"from": today, "to": today}, curr["range"]
assert curr["data"].get("period") is None, curr["data"]
assert curr["data"]["total"]["total"] == 148, curr["data"]["total"]
' "$outputs/range.json" "$outputs/range-today.json" "$today"; then
    pass "l: --since/--until bounds custom ranges and omits named period"
else
    fail "l: --since/--until" "past=$range_status today=$range_today_status"
fi

# (m) --source, --model, and --device filters restrict records before aggregation.
run "$outputs/filter-source.json" "$outputs/filter-source.err" "$bin" summary --json --period all --source claude --local-only --tz "$zone"
filter_source_status=$last_status
if [ "$filter_source_status" -eq 0 ] && "$python" -I -c '
import json, sys
doc = json.load(sys.stdin)
assert doc["data"]["total"]["total"] == 139, doc["data"]["total"]
assert [g["id"] for g in doc["data"]["bySource"]] == ["claude"], doc["data"]["bySource"]
' < "$outputs/filter-source.json"; then
    pass "m1: --source filter restricts totals and breakdowns to claude"
else
    fail "m1: --source filter" "exit $filter_source_status"
fi

run "$outputs/filter-model.json" "$outputs/filter-model.err" "$bin" summary --json --period all --model smoke-model-a --local-only --tz "$zone"
filter_model_status=$last_status
if [ "$filter_model_status" -eq 0 ] && "$python" -I -c '
import json, sys
doc = json.load(sys.stdin)
assert doc["data"]["total"]["total"] == 139, doc["data"]["total"]
assert [g["id"] for g in doc["data"]["byModel"]] == ["smoke-model-a"], doc["data"]["byModel"]
' < "$outputs/filter-model.json"; then
    pass "m2: --model filter restricts totals and breakdowns to smoke-model-a"
else
    fail "m2: --model filter" "exit $filter_model_status"
fi

run "$outputs/filter-device.json" "$outputs/filter-device.err" "$bin" summary --json --period all --device smoke-device --local-only --tz "$zone"
filter_device_status=$last_status
if [ "$filter_device_status" -eq 0 ] && "$python" -I -c '
import json, sys
doc = json.load(sys.stdin)
assert doc["data"]["total"]["total"] == 148, doc["data"]["total"]
assert [g["id"] for g in doc["data"]["byDevice"]] == ["smoke-device"], doc["data"]["byDevice"]
' < "$outputs/filter-device.json"; then
    pass "m3: --device filter restricts totals and breakdowns to smoke-device"
else
    fail "m3: --device filter" "exit $filter_device_status"
fi

if [ "$failures" -ne 0 ]; then
    exit 1
fi
