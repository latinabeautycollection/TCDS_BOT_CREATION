#!/usr/bin/env python3
import hashlib,json,os,sys,tempfile
from pathlib import Path
target=Path(sys.argv[1]).resolve(); backup=Path(sys.argv[2]).resolve()
manifest=json.loads((backup/"manifest.json").read_text())
for e in manifest["entries"]:
    rel=Path(e["path"])
    if rel.is_absolute() or ".." in rel.parts: raise SystemExit("unsafe manifest path")
    dst=(target/rel).resolve()
    if dst!=target and target not in dst.parents: raise SystemExit("path escape")
    blob=backup/"files"/e["blob"]
    if hashlib.sha256(blob.read_bytes()).hexdigest()!=e["sha256"]: raise SystemExit("backup hash mismatch")
    dst.parent.mkdir(parents=True,exist_ok=True)
    fd,tmp=tempfile.mkstemp(prefix=".restore.",dir=dst.parent)
    with os.fdopen(fd,"wb") as f: f.write(blob.read_bytes()); f.flush(); os.fsync(f.fileno())
    os.chmod(tmp,e["mode"])
    try: os.chown(tmp,e["uid"],e["gid"])
    except PermissionError: pass
    os.replace(tmp,dst)
print("Rollback completed")
