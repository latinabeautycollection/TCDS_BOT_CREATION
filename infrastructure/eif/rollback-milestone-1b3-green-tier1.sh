#!/usr/bin/env bash
set -Eeuo pipefail
T="${1:-/opt/tcds/TCDS_Enterprise_Infrastructure}";B="${2:?backup}";[[ -f "$B/backup-manifest.json" ]]||exit 5;exec 9>"$T/state/locks/framework-global-write.lock";flock -n 9||exit 7
python3 - "$T" "$B" <<'PYROLL'
import hashlib,json,shutil,sys
from pathlib import Path
t,b=map(Path,sys.argv[1:]);d=json.load(open(b/'backup-manifest.json'))
for x in d['files']:
 s=b/'files'/x['path'];assert hashlib.sha256(s.read_bytes()).hexdigest()==x['sha256'];q=t/x['path'];q.parent.mkdir(parents=True,exist_ok=True);z=q.with_name('.'+q.name+'.restore');shutil.copy2(s,z);z.replace(q)
PYROLL
echo rollback-success
