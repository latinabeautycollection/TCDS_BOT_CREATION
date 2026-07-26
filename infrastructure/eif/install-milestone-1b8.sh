#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'; umask 027
S="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
T="${1:-/opt/tcds/TCDS_Enterprise_Infrastructure}"
[[ "$T" == /* && ! -L "$T" && -x "$T/bin/eif-validate-v3" ]] || { echo "Milestone 1B.7 GT1 required" >&2; exit 5; }
[[ "$T" != /opt/* || $EUID -eq 0 ]] || { echo "Use sudo" >&2; exit 4; }
install -d -m 0750 "$T/state/locks"
exec 9>"$T/state/locks/framework-global-write.lock"; flock -n 9 || exit 7
exec 8>"$T/state/locks/milestone-1b8.lock"; flock -n 8 || exit 7
STAMP="$(date -u +%Y%m%dT%H%M%SZ)"
B="$T/backups/framework-upgrade/$STAMP"; install -d -m 0750 "$B/files"
python3 - "$S" "$T" "$B" <<'PY'
import hashlib,json,shutil,stat,sys
from pathlib import Path
s,t,b=map(Path,sys.argv[1:]);m=json.loads((s/'release_v1.4.0/release-manifest.json').read_text());a=[]
for e in m['files']:
 r=Path(e['path']);d=t/r
 if d.is_symlink():raise SystemExit('destination symlink')
 if d.is_file():
  k=hashlib.sha256(str(r).encode()).hexdigest();shutil.copy2(d,b/'files'/k);st=d.stat()
  a.append({'action':'REPLACE','path':str(r),'blob':k,'sha256':hashlib.sha256((b/'files'/k).read_bytes()).hexdigest(),'mode':stat.S_IMODE(st.st_mode),'uid':st.st_uid,'gid':st.st_gid})
 else:a.append({'action':'CREATE','path':str(r)})
(b/'plan.json').write_text(json.dumps({'entries':a},indent=2)+'\n')
PY
ST="$(mktemp -d /opt/tcds/.eif-1b8.XXXXXX 2>/dev/null || mktemp -d)"; trap 'rm -rf "$ST"' EXIT
cp -a "$T/." "$ST/"
python3 "$S/release_v1.4.0/apply_overlay.py" "$S" "$ST"
EIF_CERTIFICATION_HMAC_KEY=test-key EIF_VALIDATION_HMAC_KEY=test-key EIF_BACKUP_HMAC_KEY=test-key EIF_APPROVAL_HMAC_KEY=test-key "$ST/tests/certification/test-engine.sh"
python3 "$S/release_v1.4.0/apply_overlay.py" "$S" "$T"
if ! EIF_CERTIFICATION_HMAC_KEY=test-key EIF_VALIDATION_HMAC_KEY=test-key EIF_BACKUP_HMAC_KEY=test-key EIF_APPROVAL_HMAC_KEY=test-key "$T/tests/certification/test-engine.sh"; then
  python3 "$S/release_v1.4.0/rollback_overlay.py" "$T" "$B"
  echo "Post-install validation failed; rollback completed" >&2
  exit 8
fi
echo "Milestone 1B.8 installed successfully"
echo "Rollback backup: $B"
