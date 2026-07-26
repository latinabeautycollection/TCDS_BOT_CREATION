#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'; umask 027
S="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
T="${1:-/opt/tcds/TCDS_Enterprise_Infrastructure}"
[[ "$T" == /* && ! -L "$T" && -x "$T/bin/eif-backup-v2" ]] || { echo "Milestone 1B.6 GT1 required or unsafe target" >&2; exit 5; }
[[ "$T" != /opt/* || $EUID -eq 0 ]] || { echo "Use sudo" >&2; exit 4; }
install -d -m 0750 "$T/state/locks"
exec 9>"$T/state/locks/framework-global-write.lock"; flock -n 9 || exit 7
exec 8>"$T/state/locks/milestone-1b7.lock"; flock -n 8 || exit 7
STAMP="$(date -u +%Y%m%dT%H%M%SZ)"
B="$T/backups/framework-upgrade/$STAMP"; install -d -m 0750 "$B/files"
python3 - "$S" "$T" "$B" <<'PY'
import hashlib,json,os,shutil,stat,sys
from pathlib import Path
s,t,b=map(Path,sys.argv[1:]); entries=[]
m=json.loads((s/"release_v1.2.0/release-manifest.json").read_text())
for e in m["files"]:
    rel=Path(e["path"]); dst=t/rel
    if dst.is_symlink(): raise SystemExit("destination symlink")
    if dst.is_file():
        key=hashlib.sha256(str(rel).encode()).hexdigest(); blob=b/"files"/key
        shutil.copy2(dst,blob); st=dst.stat()
        entries.append({"action":"REPLACE","path":str(rel),"blob":key,"sha256":hashlib.sha256(blob.read_bytes()).hexdigest(),"mode":stat.S_IMODE(st.st_mode),"uid":st.st_uid,"gid":st.st_gid})
    else: entries.append({"action":"CREATE","path":str(rel)})
(b/"plan.json").write_text(json.dumps({"entries":entries},indent=2)+"\n")
PY
STAGE="$(mktemp -d /opt/tcds/.eif-1b7.XXXXXX 2>/dev/null || mktemp -d)"; trap 'rm -rf "$STAGE"' EXIT
cp -a "$T/." "$STAGE/"
python3 "$S/release_v1.2.0/apply_overlay.py" "$S" "$STAGE"
EIF_VALIDATION_HMAC_KEY=test-key "$STAGE/tests/validation_v2/test-all.sh"
EIF_VALIDATION_HMAC_KEY=test-key "$STAGE/tests/validation_v2/test-negative.sh"
python3 "$S/release_v1.2.0/apply_overlay.py" "$S" "$T"
if ! EIF_VALIDATION_HMAC_KEY=test-key "$T/tests/validation_v2/test-all.sh" || ! EIF_VALIDATION_HMAC_KEY=test-key "$T/tests/validation_v2/test-negative.sh"; then
  python3 "$S/release_v1.2.0/rollback_overlay.py" "$T" "$B"
  echo "Post-install validation failed; rollback completed" >&2
  exit 8
fi
echo "Milestone 1B.7 installed successfully"
echo "Rollback backup: $B"
