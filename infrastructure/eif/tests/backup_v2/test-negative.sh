#!/usr/bin/env bash
set -Eeuo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
cp -a "$ROOT/." "$TMP/f/"
F="$TMP/f"; SRC="$TMP/src"; mkdir -p "$SRC"; printf x > "$SRC/x"
export EIF_BACKUP_HMAC_KEY=k EIF_APPROVAL_HMAC_KEY=a
python3 - "$F/config/backup_v2/policy-v1.1.0.json" "$SRC" <<'PY'
import json,sys
p,s=sys.argv[1:];d=json.load(open(p));d["environment"]="test";d["storage"]["minimumFreeReserveBytes"]=1
d["componentContracts"]["test"]={"roots":[s],"consistencyProvider":"static_file_set","preBackupGates":[],"preRestoreGates":[],"postRestoreGates":[]}
json.dump(d,open(p,"w"),indent=2)
PY
# Unknown classification must fail.
if "$F/bin/eif-backup-v2" create test x "$SRC" --classification unknown --change-id c1 --operator-id o1 --reason bad >/dev/null 2>&1; then exit 1; fi
# Missing HMAC must fail.
unset EIF_BACKUP_HMAC_KEY
if "$F/bin/eif-backup-v2" create test x "$SRC" --change-id c2 --operator-id o1 --reason bad >/dev/null 2>&1; then exit 1; fi
export EIF_BACKUP_HMAC_KEY=k
# Creator cannot approve own production plan.
out="$("$F/bin/eif-backup-v2" create test x "$SRC" --change-id c3 --operator-id creator --reason okay)"
bid="$(python3 -c 'import json,sys;print(json.load(sys.stdin)["backupId"])' <<<"$out")"
plan="$("$F/bin/eif-backup-v2" plan "$bid" "$TMP/r" --target-class PRODUCTION_IN_PLACE --mode MERGE --change-id c3 --operator-id creator)"
pid="$(python3 -c 'import json,sys;print(json.load(sys.stdin)["planId"])' <<<"$plan")"
if "$F/bin/eif-backup-v2" approve "$pid" --approver-id creator >/dev/null 2>&1; then exit 1; fi
echo 'PASS: backup negative controls'
