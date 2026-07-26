#!/usr/bin/env bash
set -Eeuo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
cp -a "$ROOT/." "$TMP/"
E="$TMP/bin/eif-exec"
run(){ printf '%s' "$1" | EIF_ROOT="$TMP" "$E" run; }
run '{"schemaVersion":"1.0","command":"true","args":[],"operation":"test","component":"core"}' | grep -q '"status": "SUCCESS"'
run '{"schemaVersion":"1.0","command":"printf","args":["hello"],"operation":"test","component":"core","dryRun":true}' | grep -q '"status": "DRY_RUN"'
if run '{"schemaVersion":"1.0","command":"bash","args":["-c","id"],"operation":"test"}' >/dev/null 2>&1; then exit 1; else [[ $? -eq 17 ]]; fi
if run '{"schemaVersion":"1.0","command":"printf","args":["hello; id"],"operation":"test"}' >/dev/null 2>&1; then exit 1; else [[ $? -eq 17 ]]; fi
if run '{"schemaVersion":"1.0","command":"sleep","args":["3"],"operation":"timeout","component":"timer","timeoutSeconds":1}' >/dev/null 2>&1; then exit 1; else [[ $? -eq 1 ]]; fi
req='{"schemaVersion":"1.0","command":"true","args":[],"operation":"idem","component":"core","idempotencyKey":"idem-key-0001"}'
a="$(run "$req")"; b="$(run "$req")"; [[ "$(python3 -c 'import json,sys;print(json.load(sys.stdin)["executionId"])' <<<"$a")" == "$(python3 -c 'import json,sys;print(json.load(sys.stdin)["executionId"])' <<<"$b")" ]]
if run '{"schemaVersion":"1.0","command":"printf","args":["different"],"operation":"idem","component":"core","idempotencyKey":"idem-key-0001"}' >/dev/null 2>&1; then exit 1; else [[ $? -eq 19 ]]; fi
if run '{"schemaVersion":"1.0","command":"true","args":[],"operation":"env","environment":{"AWS_SECRET_ACCESS_KEY":"x"}}' >/dev/null 2>&1; then exit 1; else [[ $? -eq 17 ]]; fi
find "$TMP/state/executions" -type f -name '*.json' | grep -q .
echo 'PASS: Milestone 1B.4 controlled execution engine'
