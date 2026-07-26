#!/usr/bin/env bash
set -Eeuo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
cp -a "$ROOT/." "$TMP/"
E="$TMP/bin/eif-state"
"$E" component-get redis | grep -q '"NEW"'
"$E" component-transition redis DISCOVERED --reason test --expected-version 0 >/dev/null
if "$E" component-transition redis STAGED --reason stale --expected-version 0 >/dev/null 2>&1; then exit 1; else [[ $? -eq 20 ]]; fi
"$E" component-transition redis STAGED --reason test --expected-version 1 >/dev/null
tx="$("$E" tx-begin redis configure chg-001 idem-001)"
tid="$(python3 -c 'import json,sys; print(json.load(sys.stdin)["transactionId"])' <<<"$tx")"
"$E" tx-transition "$tid" PREPARED --reason prepare --expected-version 0 >/dev/null
file="$TMP/state/test-target"; printf 'before\n' > "$file"
"$E" checkpoint-create "$tid" pre-change "$file" >/dev/null
"$E" checkpoint-verify "$tid" pre-change >/dev/null
"$E" tx-transition "$tid" APPLYING --reason apply --expected-version 1 >/dev/null
printf 'after\n' > "$file"
"$E" tx-transition "$tid" ROLLBACK_PENDING --reason rollback --expected-version 2 >/dev/null
"$E" tx-transition "$tid" ROLLING_BACK --reason rollback --expected-version 3 >/dev/null
"$E" checkpoint-restore "$tid" pre-change >/dev/null
grep -q '^before$' "$file"
"$E" tx-transition "$tid" ROLLED_BACK --reason done --expected-version 4 >/dev/null
again="$("$E" tx-begin redis configure chg-001 idem-001)"
[[ "$(python3 -c 'import json,sys; print(json.load(sys.stdin)["transactionId"])' <<<"$again")" == "$tid" ]]
tx2="$("$E" tx-begin envoy deploy chg-002 idem-002)"
tid2="$(python3 -c 'import json,sys; print(json.load(sys.stdin)["transactionId"])' <<<"$tx2")"
"$E" tx-transition "$tid2" PREPARED --reason prepare --expected-version 0 >/dev/null
"$E" tx-transition "$tid2" APPLYING --reason apply --expected-version 1 >/dev/null
"$E" reconcile | grep -q "$tid2"
"$E" tx-get "$tid2" | grep -q RECOVERY_REQUIRED
"$E" verify-journal >/dev/null
echo 'PASS: Milestone 1B.5 state and transaction engine'
