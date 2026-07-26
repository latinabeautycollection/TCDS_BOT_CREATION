#!/usr/bin/env python3
import hashlib,json,os,shutil,stat,sys,tempfile
from pathlib import Path
target=Path(sys.argv[1]);backup=Path(sys.argv[2])
m=json.loads((backup/"backup-manifest.json").read_text())
for e in m["entries"]:
 rel=Path(e["path"])
 if rel.is_absolute() or ".." in rel.parts:raise SystemExit("unsafe manifest path")
 src=backup/"files"/rel;dst=target/rel
 if hashlib.sha256(src.read_bytes()).hexdigest()!=e["sha256"]:raise SystemExit("backup corruption")
 cur=target
 for part in rel.parts[:-1]:
  cur=cur/part
  if cur.exists() and cur.is_symlink():raise SystemExit(f"symlink destination: {cur}")
  cur.mkdir(exist_ok=True,mode=0o750)
 fd,tmp=tempfile.mkstemp(prefix="."+dst.name+".",dir=dst.parent);os.close(fd);shutil.copyfile(src,tmp)
 os.chmod(tmp,e["mode"]);os.chown(tmp,e["uid"],e["gid"]);os.replace(tmp,dst)
print("rollback restored verified files")
