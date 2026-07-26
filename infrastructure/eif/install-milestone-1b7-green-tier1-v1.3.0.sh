#!/usr/bin/env bash
set -Eeuo pipefail
S="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)";T="${1:-/opt/tcds/TCDS_Enterprise_Infrastructure}"
[[ "$T" == /* && ! -L "$T" && -x "$T/bin/eif-backup-v2" ]] || exit 5
[[ "$T" != /opt/* || $EUID -eq 0 ]] || exit 4
install -d -m 0750 "$T/state/locks";exec 9>"$T/state/locks/framework-global-write.lock";flock -n 9 || exit 7
exec 8>"$T/state/locks/milestone-1b7-v130.lock";flock -n 8 || exit 7
STAMP="$(date -u +%Y%m%dT%H%M%SZ)";B="$T/backups/framework-upgrade/$STAMP";install -d -m 0750 "$B/files"
python3 - "$S" "$T" "$B" <<'PY'
import hashlib,json,shutil,stat,sys
from pathlib import Path
s,t,b=map(Path,sys.argv[1:]);m=json.loads((s/'release_v1.3.0/release-manifest.json').read_text());a=[]
for e in m['files']:
 r=Path(e['path']);d=t/r
 if d.is_symlink():raise SystemExit('symlink')
 if d.is_file():
  k=hashlib.sha256(str(r).encode()).hexdigest();shutil.copy2(d,b/'files'/k);st=d.stat()
  a.append({'action':'REPLACE','path':str(r),'blob':k,'sha256':hashlib.sha256((b/'files'/k).read_bytes()).hexdigest(),'mode':stat.S_IMODE(st.st_mode),'uid':st.st_uid,'gid':st.st_gid})
 else:a.append({'action':'CREATE','path':str(r)})
(b/'plan.json').write_text(json.dumps({'entries':a},indent=2)+'\n')
PY
ST="$(mktemp -d /opt/tcds/.eif-1b7-v130.XXXXXX 2>/dev/null || mktemp -d)";trap 'rm -rf "$ST"' EXIT;cp -a "$T/." "$ST/"
python3 "$S/release_v1.3.0/apply_overlay.py" "$S" "$ST";EIF_VALIDATION_HMAC_KEY=testkey "$ST/tests/validation_v3/test-all.sh"
python3 "$S/release_v1.3.0/apply_overlay.py" "$S" "$T"
if ! EIF_VALIDATION_HMAC_KEY=testkey "$T/tests/validation_v3/test-all.sh";then python3 "$S/release_v1.3.0/rollback_overlay.py" "$T" "$B";exit 8;fi
echo "Milestone 1B.7 Green Tier 1 v1.3.0 installed";echo "Rollback backup: $B"
