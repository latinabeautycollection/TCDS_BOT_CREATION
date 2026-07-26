#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'; umask 027
S="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"; T="${1:-/opt/tcds/TCDS_Enterprise_Infrastructure}"; TS="$(date -u +%Y%m%dT%H%M%SZ)"
O="${SUDO_USER:-${USER:-root}}"; G="$(id -gn "$O" 2>/dev/null || echo root)"
[[ "$T" == /* && ! -L "$T" && -f "$T/bin/eif-log-v2" ]] || { echo 'Milestone 1B.3 GT1 required or unsafe target' >&2; exit 5; }
[[ "$T" != /opt/* || $EUID -eq 0 ]] || exit 4
install -d -m 0750 -o "$O" -g "$G" "$T/state/locks"
exec 9>"$T/state/locks/framework-global-write.lock"; flock -n 9 || exit 7
exec 8>"$T/state/locks/milestone-1b4.lock"; flock -n 8 || exit 7
B="$T/backups/framework-upgrade/$TS"; install -d -m 0750 -o "$O" -g "$G" "$B/files"
M="$B/backup-manifest.json"; python3 - "$S" "$T" "$B" "$M" <<'PYB'
import hashlib,json,os,shutil,sys
s,t,b,m=map(os.path.abspath,sys.argv[1:]); entries=[]
for dp,ds,fs in os.walk(s):
 ds[:]=[d for d in ds if d not in {'__pycache__','state','logs','events','backups','runtime'}]
 for n in fs:
  src=os.path.join(dp,n); rel=os.path.relpath(src,s)
  if rel in {'install-milestone-1b4.sh','rollback-milestone-1b4.sh'}:continue
  dst=os.path.join(t,rel)
  if os.path.islink(dst):raise SystemExit('symlink collision '+dst)
  if os.path.isfile(dst):
   out=os.path.join(b,'files',rel);os.makedirs(os.path.dirname(out),exist_ok=True);shutil.copy2(dst,out)
   h=hashlib.sha256(open(out,'rb').read()).hexdigest();entries.append({'path':rel,'sha256':h,'existed':True})
  else:entries.append({'path':rel,'existed':False})
with open(m+'.tmp','w') as f:json.dump({'schemaVersion':'1.0','entries':entries},f,indent=2);f.write('\n')
os.replace(m+'.tmp',m)
PYB
ST="$(mktemp -d)"; trap 'rm -rf "$ST"' EXIT; cp -a "$T/." "$ST/"
apply(){ local D="$1"; while IFS= read -r -d '' F; do R="${F#"$S/"}"; case "$R" in install-milestone-1b4.sh|rollback-milestone-1b4.sh|state/*|logs/*|events/*|backups/*|runtime/*|*/__pycache__/*) continue;; esac; X="$D/$R"; [[ ! -L "$X" ]]||exit 3; install -d -m 0750 "$(dirname "$X")"; P="$(dirname "$X")/.${X##*/}.new.$$"; install -m 0640 "$F" "$P"; case "$R" in *.sh|*.py|bin/*) chmod 0750 "$P";; esac; mv -f "$P" "$X"; done < <(find "$S" -type f -print0); }
apply "$ST"; EIF_ROOT="$ST" "$ST/tests/execution/test-all.sh"; apply "$T"; chown "$O:$G" "$T/framework/execution/execution_engine.py" "$T/framework/execution/execution.sh" "$T/bin/eif-exec" "$T/config/upgrade/execution-v0.6.0.json" "$T/schemas/execution/request.schema.json" "$T/tests/execution/test-all.sh" "$T/docs/MILESTONE-1B4.md" "$T/migrations/0.5.0-to-0.6.0.json" "$T/VERSION"
EIF_ROOT="$T" "$T/tests/execution/test-all.sh"
echo "Milestone 1B.4 installed and validated. Backup: $B"
