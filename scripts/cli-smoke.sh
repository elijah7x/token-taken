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
# TokenTakenKit/SQLiteUsageStore.swift, including the final health columns and user_version 2.
create_store() {
    if [ -f "$database" ]; then
        return 0
    fi
    "$sqlite" "$database" <<'SQL'
CREATE TABLE IF NOT EXISTS devices (
    id TEXT PRIMARY KEY, name TEXT NOT NULL, last_seen REAL NOT NULL
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
    event_count INTEGER NOT NULL,
    PRIMARY KEY (device_id, source_id, model_id, day)
);
CREATE TABLE IF NOT EXISTS hourly_usage (
    device_id TEXT NOT NULL, source_id TEXT NOT NULL, hour_start INTEGER NOT NULL,
    input INTEGER NOT NULL, cache_read INTEGER NOT NULL, cache_write INTEGER NOT NULL,
    output INTEGER NOT NULL, reasoning INTEGER NOT NULL, uncategorized INTEGER NOT NULL,
    event_count INTEGER NOT NULL, reasoning_known INTEGER NOT NULL,
    PRIMARY KEY (device_id, source_id, hour_start)
);
PRAGMA user_version = 2;
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
    ('smoke-device', 'claude', 'smoke-model-a', 'smoke-model-a', '$today', '$zone', 100, 20, 10, 5, 3, 1, 4),
    ('smoke-device', 'codex', 'smoke-model-b', 'smoke-model-b', '$today', '$zone', 7, 0, 0, 2, 0, 0, 1);
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
          "cacheWrite,output,reasoning,uncategorized,total,eventCount").split(",")
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

if [ "$failures" -ne 0 ]; then
    exit 1
fi
