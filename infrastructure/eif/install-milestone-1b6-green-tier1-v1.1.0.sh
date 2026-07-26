#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'; umask 027
S="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
T="${1:-/opt/tcds/TCDS_Enterprise_Infrastructure}"
[[ "$T" == /* && ! -L "$T" && -x "$T/bin/eif-state-v2" ]] || { echo "Milestone 1B.5 GT1 required or unsafe target" >&2; exit 5; }
[[ "$T" != /opt/* || $EUID -eq 0 ]] || { echo "Use sudo" >&2; exit 4; }
python3 "$S/release_v1.1.0/verify_release.py" "$S"
install -d -m 0750 "$T/state/locks"
exec 9>"$T/state/locks/framework-global-write.lock"; flock -n 9 || exit 7
exec 8>"$T/state/locks/milestone-1b6-v1.1.0.lock"; flock -n 8 || exit 7
STAMP="$(date -u +%Y%m%dT%H%M%SZ)"
B="$T/backups/framework-upgrade/$STAMP"; install -d -m 0750 "$B/files"
python3 - "$S" "$T" "$B" <<'PY'
import hashlib,json,os,shutil,stat,sys
from pathlib import Path
s,t,b=map(Path,sys.argv[1:])
entries=[]
manifest=json.loads((s/"release_v1.1.0/release-manifest.json").read_text())
for item in manifest["files"]:
    rel=Path(item["path"]); dst=t/rel
    if dst.is_symlink(): raise SystemExit(f"destination symlink: {rel}")
    if dst.is_file():
        key=hashlib.sha256(str(rel).encode()).hexdigest(); blob=b/"files"/key
        blob.parent.mkdir(parents=True,exist_ok=True); shutil.copy2(dst,blob)
        st=dst.stat()
        entries.append({"action":"REPLACE","path":str(rel),"blob":key,"sha256":hashlib.sha256(blob.read_bytes()).hexdigest(),
                        "mode":stat.S_IMODE(st.st_mode),"uid":st.st_uid,"gid":st.st_gid})
    else:
        entries.append({"action":"CREATE","path":str(rel)})
plan={"schemaVersion":"1.0","releaseVersion":"1.1.0","entries":entries}
(b/"upgrade-plan.json").write_text(json.dumps(plan,indent=2)+"\n")
PY
STAGE="$(mktemp -d /opt/tcds/.eif-1b6-v110.XXXXXX 2>/dev/null || mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT
cp -a "$T/." "$STAGE/"
python3 - "$S" "$STAGE" <<'PY'
import json,os,shutil,stat,sys,tempfile
from pathlib import Path
s,t=map(Path,sys.argv[1:])
m=json.loads((s/"release_v1.1.0/release-manifest.json").read_text())
for e in m["files"]:
    src=s/e["path"]; dst=t/e["path"]; dst.parent.mkdir(parents=True,exist_ok=True)
    fd,tmp=tempfile.mkstemp(prefix=".upgrade.",dir=dst.parent)
    with os.fdopen(fd,"wb") as f:f.write(src.read_bytes());f.flush();os.fsync(f.fileno())
    os.chmod(tmp,int(e["mode"],8));os.replace(tmp,dst)
PY
"$STAGE/tests/backup_v2/test-all.sh"
"$STAGE/tests/backup_v2/test-negative.sh"
apply_prod() {
python3 - "$S" "$T" <<'PY'
import json,os,tempfile,sys
from pathlib import Path
s,t=map(Path,sys.argv[1:])
m=json.loads((s/"release_v1.1.0/release-manifest.json").read_text())
for e in m["files"]:
    src=s/e["path"]; dst=t/e["path"]; dst.parent.mkdir(parents=True,exist_ok=True)
    if dst.is_symlink(): raise SystemExit("destination symlink")
    fd,tmp=tempfile.mkstemp(prefix=".upgrade.",dir=dst.parent)
    with os.fdopen(fd,"wb") as f:f.write(src.read_bytes());f.flush();os.fsync(f.fileno())
    os.chmod(tmp,int(e["mode"],8));os.replace(tmp,dst)
PY
}
rollback() {
python3 - "$T" "$B" <<'PY'
import hashlib,json,os,sys,tempfile
from pathlib import Path
t,b=map(Path,sys.argv[1:])
p=json.loads((b/"upgrade-plan.json").read_text())
for e in reversed(p["entries"]):
    rel=Path(e["path"])
    if rel.is_absolute() or ".." in rel.parts: raise SystemExit("unsafe rollback path")
    dst=(t/rel).resolve(); rt=t.resolve()
    if dst!=rt and rt not in dst.parents: raise SystemExit("path escape")
    if e["action"]=="CREATE":
        if dst.is_file() and not dst.is_symlink(): dst.unlink()
    else:
        blob=b/"files"/e["blob"]
        if hashlib.sha256(blob.read_bytes()).hexdigest()!=e["sha256"]: raise SystemExit("backup corruption")
        dst.parent.mkdir(parents=True,exist_ok=True)
        fd,tmp=tempfile.mkstemp(prefix=".rollback.",dir=dst.parent)
        with os.fdopen(fd,"wb") as f:f.write(blob.read_bytes());f.flush();os.fsync(f.fileno())
        os.chmod(tmp,e["mode"])
        try:os.chown(tmp,e["uid"],e["gid"])
        except PermissionError:raise SystemExit("ownership restore failed")
        os.replace(tmp,dst)
PY
}
if ! apply_prod || ! "$T/tests/backup_v2/test-all.sh" || ! "$T/tests/backup_v2/test-negative.sh"; then
  rollback
  "$T/bin/eif" doctor >/dev/null 2>&1 || true
  echo "Installation failed; verified rollback applied" >&2
  exit 8
fi
echo "Milestone 1B.6 Green Tier 1 v1.1.0 installed successfully"
echo "Rollback plan: $B/upgrade-plan.json"
