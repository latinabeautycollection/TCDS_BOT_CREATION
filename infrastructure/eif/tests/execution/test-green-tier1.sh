#!/usr/bin/env bash
set -Eeuo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
cp -a "$ROOT/." "$TMP/"
export EIF_ROOT="$TMP"
python3 "$TMP/framework/execution/build_trust_manifest.py" "$TMP"
export EIF_RECEIPT_HMAC_KEY=test-only-key EIF_EXEC_AUDIT_TEST_FALLBACK=1
req='{"schemaVersion":"2.0","command":"true","args":[],"operation":"smoke","component":"framework","idempotencyKey":"smoke-1","correlation":{"run_id":"run-1","change_id":"chg-1","operator_id":"tester"}}'
printf '%s' "$req" | "$TMP/bin/eif-exec-v2" validate >/dev/null
printf '%s' "$req" | "$TMP/bin/eif-exec-v2" run >/dev/null
printf '%s' "$req" | "$TMP/bin/eif-exec-v2" run >/dev/null
test "$(find "$TMP/state/executions/receipts" -name '*.json' | wc -l)" -ge 1
grep -R '"receiptHmac"' "$TMP/state/executions/receipts" >/dev/null

bad='{"schemaVersion":"2.0","command":"true","operation":"smoke","component":"../x","correlation":{"run_id":"run-1","change_id":"chg-1","operator_id":"tester"}}'
if printf '%s' "$bad" | "$TMP/bin/eif-exec-v2" run >/dev/null 2>&1; then exit 1; else [[ $? -eq 6 ]]; fi

unknown='{"schemaVersion":"2.0","command":"true","operation":"smoke","component":"framework","unexpected":1,"correlation":{"run_id":"run-1","change_id":"chg-1","operator_id":"tester"}}'
if printf '%s' "$unknown" | "$TMP/bin/eif-exec-v2" run >/dev/null 2>&1; then exit 1; else [[ $? -eq 6 ]]; fi

python='{"schemaVersion":"2.0","command":"python-test","operation":"smoke","component":"framework","correlation":{"run_id":"run-1","change_id":"chg-1","operator_id":"tester"}}'
if printf '%s' "$python" | "$TMP/bin/eif-exec-v2" run >/dev/null 2>&1; then exit 1; else [[ $? -eq 17 ]]; fi

timeout='{"schemaVersion":"2.0","command":"sleep","args":["5"],"operation":"timeout","component":"framework","timeoutSeconds":1,"correlation":{"run_id":"run-1","change_id":"chg-1","operator_id":"tester"}}'
if printf '%s' "$timeout" | "$TMP/bin/eif-exec-v2" run >/dev/null 2>&1; then exit 1; else [[ $? -eq 18 ]]; fi

echo "PASS: Milestone 1B.4 Green Tier 1"
