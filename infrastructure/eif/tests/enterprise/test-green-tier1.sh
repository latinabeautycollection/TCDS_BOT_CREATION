#!/usr/bin/env bash
set -Eeuo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)"
export EIF_ROOT="$ROOT" EIF_ENVIRONMENT=test
source "$ROOT/framework/core/framework.sh"
rm -f "$ROOT/state/components/redis.json" "$ROOT/inventory/baselines/gt1-test.json" "$ROOT/inventory/reports/drift-gt1-test.json"

"$ROOT/bin/eif" registry-build >/dev/null
order="$("$ROOT/bin/eif" registry-order redis)"
grep -q '"packages"' <<<"$order"
grep -q '"systemd"' <<<"$order"
grep -q '"redis"' <<<"$order"

state="$("$ROOT/bin/eif" state-get redis)"
grep -q '"NEW"' <<<"$state"
"$ROOT/bin/eif" state-transition redis DISCOVERED test >/dev/null
"$ROOT/bin/eif" state-transition redis STAGED test >/dev/null

txn="$("$ROOT/bin/eif" transaction-begin redis test-operation)"
tid="$(python3 -c 'import json,sys; print(json.load(sys.stdin)["transactionId"])' <<<"$txn")"
"$ROOT/bin/eif" transaction-update "$tid" validate PASS ok >/dev/null
"$ROOT/bin/eif" transaction-finish "$tid" COMMITTED >/dev/null

tmp="$(mktemp)"
trap 'rm -f "$tmp"' EXIT
printf 'alpha\n' > "$tmp"
"$ROOT/bin/eif" drift-baseline gt1-test "$tmp" >/dev/null
"$ROOT/bin/eif" drift-check gt1-test >/dev/null
printf 'beta\n' > "$tmp"
if "$ROOT/bin/eif" drift-check gt1-test >/dev/null 2>&1; then
  echo "drift test failed" >&2; exit 1
else
  [[ $? -eq 10 ]]
fi

"$ROOT/framework/enterprise/enterprise_engine.py" --root "$ROOT" secret-validate secret://vault/path/to/key >/dev/null
"$ROOT/framework/enterprise/enterprise_engine.py" --root "$ROOT" secret-validate secret://aws/secret-id >/dev/null
"$ROOT/framework/enterprise/enterprise_engine.py" --root "$ROOT" secret-validate secret://azure/vault/name >/dev/null
"$ROOT/framework/enterprise/enterprise_engine.py" --root "$ROOT" secret-validate secret://gcp/project/secret >/dev/null

doctor="$("$ROOT/bin/eif" doctor)"
grep -q '"status": "PASS"' <<<"$doctor"
printf 'PASS: Green Tier 1 enterprise controls\n'
