#!/usr/bin/env python3
import json,os,sys,tempfile
from pathlib import Path
s,t=map(Path,sys.argv[1:])
m=json.loads((s/"release_v1.2.0/release-manifest.json").read_text())
for e in m["files"]:
    src=s/e["path"]; dst=t/e["path"]; dst.parent.mkdir(parents=True,exist_ok=True)
    if dst.is_symlink(): raise SystemExit("destination symlink")
    fd,tmp=tempfile.mkstemp(prefix=".upgrade.",dir=dst.parent)
    with os.fdopen(fd,"wb") as f:f.write(src.read_bytes());f.flush();os.fsync(f.fileno())
    os.chmod(tmp,int(e["mode"],8));os.replace(tmp,dst)
