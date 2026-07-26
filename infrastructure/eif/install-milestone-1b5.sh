#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'; umask 027
S="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
T="${1:-/opt/tcds/TCDS_Enterprise_Infrastructure}"
[[ "$T" == /* ]] || exit 2
case "$T" in /|/opt|/opt/tcds|/etc|/usr|/var) exit 3;; esac
[[ ! -L "$T" && -f "$T/framework/execution/execution_engine_v2.py" ]] || { echo "Milestone 1B.4 GT1 required" >&2; exit 5; }
[[ "$T" != /opt/* || $EUID -eq 0 ]] || { echo "Use sudo" >&2; exit 4; }
install -d -m 0750 "$T/state/locks"
exec 9>"$T/state/locks/framework-global-write.lock"; flock -n 9 || exit 7
exec 8>"$T/state/locks/milestone-1b5.lock"; flock -n 8 || exit 7
STAMP="$(date -u +%Y%m%dT%H%M%SZ)"
BACKUP="$T/backups/framework-upgrade/$STAMP"; install -d -m 0750 "$BACKUP/files"
python3 - "$S" "$T" "$BACKUP" <<'PY'
import hashlib,json,os,shutil,stat,sys
from pathlib import Path
s,t,b=map(Path,sys.argv[1:])
entries=[]
for src in s.rglob("*"):
    if not src.is_file() or src.is_symlink(): continue
    rel=src.relative_to(s)
    if str(rel) in {"install-milestone-1b5.sh","rollback-milestone-1b5.py"}: continue
    dst=t/rel
    if dst.is_file() and not dst.is_symlink():
        key=hashlib.sha256(str(rel).encode()).hexdigest()
        blob=b/"files"/key; shutil.copy2(dst,blob)
        st=dst.stat()
        entries.append({"path":str(rel),"blob":key,"sha256":hashlib.sha256(blob.read_bytes()).hexdigest(),
                        "mode":stat.S_IMODE(st.st_mode),"uid":st.st_uid,"gid":st.st_gid})
(b/"manifest.json").write_text(json.dumps({"schemaVersion":"1.0","entries":entries},indent=2)+"\n")
PY
STAGE="$(mktemp -d)"; trap 'rm -rf "$STAGE"' EXIT
cp -a "$T/." "$STAGE/"
python3 "$S/release/apply_overlay.py" "$S" "$STAGE"
"$STAGE/tests/state/test-all.sh"
python3 "$S/release/apply_overlay.py" "$S" "$T"
"$T/tests/state/test-all.sh"
echo "Milestone 1B.5 installed successfully"
echo "Rollback backup: $BACKUP"
