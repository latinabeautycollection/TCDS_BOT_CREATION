#!/usr/bin/env bash
set -Eeuo pipefail
R="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)"; T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT; cp -a "$R/." "$T/"; E="$T/bin/eif-state-v2"
mkdir -p "$T/tmp"; python3 - "$T/config/components/checkpoint-allowlists.json" "$T" <<'P'
import json,sys
p,r=sys.argv[1:]; d=json.load(open(p)); d['framework']=[r+'/tmp',r+'/config']; open(p,'w').write(json.dumps(d))
P
x="$($E begin framework configure chg-1 idem-1 --correlation-json '{"run_id":"run-1"}')"; id="$(python3 -c 'import json,sys;print(json.load(sys.stdin)["transactionId"])' <<<"$x")"
if $E begin envoy deploy chg-2 idem-1 >/dev/null 2>&1; then exit 1; else [[ $? -eq 20 ]]; fi
$E transition "$id" PREPARED --reason ok --expected-version 0 >/dev/null
printf before > "$T/tmp/a"; $E checkpoint "$id" cp1 "$T/tmp/a" --expected-version 1 >/dev/null
for g in checkpoint_verified change_plan_approved execution_authorized dependencies_healthy; do $E gate "$id" "$g" PASS --evidence ev-$g >/dev/null; done
v="$(python3 - "$T/state/database/state-v0.9.0.sqlite3" "$id" <<'P'
import sqlite3,sys,json
c=sqlite3.connect(sys.argv[1]);print(json.loads(c.execute('select document from transactions where id=?',(sys.argv[2],)).fetchone()[0])['version'])
P
)"
$E transition "$id" APPLYING --reason go --expected-version "$v" >/dev/null
$E lease "$id" --seconds 10 --receipt r1 >/dev/null
$E verify >/dev/null
$E saga-create saga-1 --steps-json '["envoy-validate","suricata-validate","pqp-ready","run-canary","evidence-verify","seal"]' >/dev/null
echo 'PASS: Milestone 1B.5 Green Tier 1 v0.9.0'
