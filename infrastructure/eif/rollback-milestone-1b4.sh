#!/usr/bin/env bash
set -Eeuo pipefail
T="${1:-/opt/tcds/TCDS_Enterprise_Infrastructure}"; B="${2:?backup directory required}"; M="$B/backup-manifest.json"
[[ -f "$M" ]]||exit 5; exec 9>"$T/state/locks/framework-global-write.lock";flock -n 9||exit 7
python3 - "$T" "$B" "$M" <<'PYR'
import hashlib,json,os,shutil,sys
t,b,m=map(os.path.abspath,sys.argv[1:]);doc=json.load(open(m))
for e in doc['entries']:
 dst=os.path.join(t,e['path'])
 if e['existed']:
  src=os.path.join(b,'files',e['path']);h=hashlib.sha256(open(src,'rb').read()).hexdigest()
  if h!=e['sha256']:raise SystemExit('backup hash failure '+e['path'])
  os.makedirs(os.path.dirname(dst),exist_ok=True);tmp=dst+'.rollback';shutil.copy2(src,tmp);os.replace(tmp,dst)
 elif os.path.exists(dst) and not os.path.isdir(dst):os.unlink(dst)
print('Milestone 1B.4 rollback complete')
PYR
