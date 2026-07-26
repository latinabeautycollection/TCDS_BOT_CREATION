#!/usr/bin/env bash
set -Eeuo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
cp -a "$ROOT/." "$TMP/framework/"
F="$TMP/framework"; SRC="$TMP/source"; mkdir -p "$SRC/sub"; printf 'alpha\n' > "$SRC/a.conf"; printf 'beta\n' > "$SRC/sub/b.rules"
python3 - "$F/config/backup/policy-v1.0.0.json" "$SRC" <<'PY'
import json,sys
p,src=sys.argv[1:];d=json.load(open(p));d['componentRoots']['test']=[src];d['storage']['minimumFreeReserveBytes']=1;json.dump(d,open(p,'w'),indent=2)
PY
out="$($F/bin/eif-backup create test baseline "$SRC")"
bid="$(python3 -c 'import json,sys;print(json.load(sys.stdin)["backupId"])' <<<"$out")"
$F/bin/eif-backup verify "$bid" >/dev/null
plan="$($F/bin/eif-backup plan "$bid" "$TMP/restore")"
pid="$(python3 -c 'import json,sys;print(json.load(sys.stdin)["planId"])' <<<"$plan")"
challenge="$(python3 -c 'import json,sys;print(json.load(sys.stdin)["approvalChallenge"])' <<<"$plan")"
$F/bin/eif-backup rehearse "$pid" >/dev/null
$F/bin/eif-backup eligibility "$pid" | grep -q '"eligible": true'
$F/bin/eif-backup restore "$pid" --approval-challenge "$challenge" >/dev/null
grep -q alpha "$TMP/restore/${SRC#/}/a.conf"
grep -q beta "$TMP/restore/${SRC#/}/sub/b.rules"
mkdir "$TMP/export"; $F/bin/eif-backup export-file "$bid" "$TMP/export" >/dev/null
$F/bin/eif-backup verify-events >/dev/null
if $F/bin/eif-backup create test bad /etc/passwd >/dev/null 2>&1; then exit 1; fi
ln -s "$SRC/a.conf" "$SRC/link"; if $F/bin/eif-backup create test symlink "$SRC" >/dev/null 2>&1; then exit 1; fi
$F/bin/eif-backup prune --dry-run >/dev/null
echo 'PASS: Milestone 1B.6 backup and rollback engine'
