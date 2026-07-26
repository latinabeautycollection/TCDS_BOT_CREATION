#!/usr/bin/env python3
import hashlib,json,os,sys,tempfile
from pathlib import Path
t,b=map(Path,sys.argv[1:]); p=json.loads((b/"plan.json").read_text())
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
        os.chmod(tmp,e["mode"]);os.chown(tmp,e["uid"],e["gid"]);os.replace(tmp,dst)
