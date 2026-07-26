#!/usr/bin/env bash
set -Eeuo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
cp -a "$ROOT/." "$TMP/framework/"
F="$TMP/framework"; SRC="$TMP/source"; mkdir -p "$SRC/sub"
printf 'alpha\n' > "$SRC/a.conf"; printf 'beta\n' > "$SRC/sub/b.rules"
export EIF_BACKUP_HMAC_KEY=test-backup-key EIF_APPROVAL_HMAC_KEY=test-approval-key
python3 - "$F/config/backup_v2/policy-v1.1.0.json" "$SRC" <<'PY'
import json,sys
p,src=sys.argv[1:]
d=json.load(open(p)); d["environment"]="test"; d["transactionIntegration"]["requiredInProduction"]=False
d["storage"]["minimumFreeReserveBytes"]=1
d["componentContracts"]["test"]={"roots":[src],"consistencyProvider":"static_file_set","preBackupGates":[],
"preRestoreGates":[],"postRestoreGates":[]}
json.dump(d,open(p,"w"),indent=2)
PY
out="$("$F/bin/eif-backup-v2" create test baseline "$SRC" --change-id chg-001 --operator-id creator --reason 'unit test backup')"
bid="$(python3 -c 'import json,sys;print(json.load(sys.stdin)["backupId"])' <<<"$out")"
"$F/bin/eif-backup-v2" verify "$bid" >/dev/null
plan="$("$F/bin/eif-backup-v2" plan "$bid" "$TMP/restore" --target-class STAGING --mode MERGE --change-id chg-001 --operator-id creator)"
pid="$(python3 -c 'import json,sys;print(json.load(sys.stdin)["planId"])' <<<"$plan")"
"$F/bin/eif-backup-v2" rehearse "$pid" >/dev/null
"$F/bin/eif-backup-v2" restore "$pid" --pre-gates-json '[]' --post-gates-json '[]' >/dev/null
grep -q alpha "$TMP/restore/${SRC#/}/a.conf"
grep -q beta "$TMP/restore/${SRC#/}/sub/b.rules"
"$F/bin/eif-backup-v2" verify-events >/dev/null
"$F/bin/eif-backup-v2" eligibility "$bid" | grep -q '"eligible": true'
if "$F/bin/eif-backup-v2" create test bad /etc/passwd --change-id chg-002 --operator-id creator --reason bad >/dev/null 2>&1; then exit 1; fi
ln -s "$SRC/a.conf" "$SRC/link"
if "$F/bin/eif-backup-v2" create test symlink "$SRC" --change-id chg-003 --operator-id creator --reason bad >/dev/null 2>&1; then exit 1; fi
if "$F/bin/eif-backup-v2" create test secret "$SRC/a.conf" --classification private-key --change-id chg-004 --operator-id creator --reason secret >/dev/null 2>&1; then exit 1; fi
"$F/bin/eif-backup-v2" prune --dry-run >/dev/null
"$F/bin/eif-backup-v2" reconcile >/dev/null
echo 'PASS: Milestone 1B.6 Green Tier 1 v1.1.0'
