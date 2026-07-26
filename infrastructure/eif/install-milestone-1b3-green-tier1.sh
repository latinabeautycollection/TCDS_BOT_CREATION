#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t';umask 027
S="$(cd "$(dirname "${BASH_SOURCE[0]}")"&&pwd -P)";T="${1:-/opt/tcds/TCDS_Enterprise_Infrastructure}";TS="$(date -u +%Y%m%dT%H%M%SZ)"
[[ "$T" == /* && ! -L "$T" && -f "$T/framework/logging/log_engine.py" ]]||exit 5;[[ "$T" != /opt/* || $EUID -eq 0 ]]||exit 4
install -d -m 0750 "$T/state/locks";exec 9>"$T/state/locks/framework-global-write.lock";flock -n 9||exit 7;exec 8>"$T/state/locks/milestone-1b3-gt1.lock";flock -n 8||exit 7
FREE=$(df -Pk "$T"|awk 'NR==2{print $4}');NEED=$(du -sk "$T"|awk '{print $1}');((FREE>NEED*2))||exit 19
B="$T/backups/framework-upgrade/$TS";install -d -m 0750 "$B/files"
python3 - "$T" "$B" <<'PYBACK'
import hashlib,json,shutil,stat,sys
from pathlib import Path
s,b=map(Path,sys.argv[1:]);rows=[]
for p in s.rglob('*'):
 if b in p.parents or p.is_symlink() or not p.is_file() or not stat.S_ISREG(p.stat().st_mode):continue
 r=p.relative_to(s);q=b/'files'/r;q.parent.mkdir(parents=True,exist_ok=True);shutil.copy2(p,q);rows.append({'path':str(r),'sha256':hashlib.sha256(p.read_bytes()).hexdigest()})
json.dump({'files':rows},open(b/'backup-manifest.json','w'),indent=2)
for x in rows:assert hashlib.sha256((b/'files'/x['path']).read_bytes()).hexdigest()==x['sha256']
PYBACK
ST=$(mktemp -d);trap 'rm -rf "$ST"' EXIT;cp -a "$T/." "$ST/"
apply(){ src="$1";rel="${src#$S/}";dst="$2/$rel";[[ ! -L "$dst" ]]||exit 3;install -d -m 0750 "$(dirname "$dst")";tmp="$(dirname "$dst")/.${dst##*/}.new.$$";install -m 0640 "$src" "$tmp";case "$rel" in *.sh|*.py|bin/*)chmod 0750 "$tmp";;esac;mv -f "$tmp" "$dst";}
while IFS= read -r -d '' f;do apply "$f" "$ST";done < <(find "$S" -type f -print0)
python3 - "$ST/config/defaults/framework.json" "$S/config/upgrade/logging-v0.5.0.json" <<'PYCFG'
import json,sys
p,o=sys.argv[1:];a=json.load(open(p));b=json.load(open(o))
def m(x,y):
 for k,v in y.items():x[k]=m(x.get(k,{}),v) if isinstance(v,dict) and isinstance(x.get(k),dict) else v
 return x
json.dump(m(a,b),open(p,'w'),indent=2);open(p,'a').write('\n')
PYCFG
EIF_ROOT="$ST" "$ST/tests/green-tier1/test-all.sh"
while IFS= read -r -d '' f;do apply "$f" "$T";done < <(find "$S" -type f -print0);cp "$ST/config/defaults/framework.json" "$T/config/defaults/framework.json";printf '0.5.0\n' > "$T/VERSION";EIF_ROOT="$T" "$T/tests/green-tier1/test-all.sh"
M="$T/manifests/installations/milestone-1b3-green-tier1-$TS.json";install -d -m 0750 "$(dirname "$M")";printf '{"milestone":"1B.3-GT1","version":"0.5.0","status":"SUCCESS","backup":"%s","serviceChanges":false}\n' "$B">"$M";chmod 0640 "$M";echo "SUCCESS backup=$B manifest=$M"
