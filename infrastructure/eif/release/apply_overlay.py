#!/usr/bin/env python3
import os,shutil,stat,sys,tempfile
from pathlib import Path
src=Path(sys.argv[1]);dst=Path(sys.argv[2])
skip={"release/manifest.json","release/verify_release.py","release/create_backup.py","release/apply_overlay.py",
      "install-milestone-1b4-green-tier1.sh"}
for p in src.rglob("*"):
 if not p.is_file():continue
 rel=str(p.relative_to(src))
 if rel in skip or rel.startswith(("state/","logs/","events/","backups/","inventory/reports/")):continue
 target=dst/rel
 target.parent.mkdir(parents=True,exist_ok=True,mode=0o750)
 if target.is_symlink():raise SystemExit(f"symlink collision: {target}")
 fd,tmp=tempfile.mkstemp(prefix="."+target.name+".",dir=target.parent)
 os.close(fd);shutil.copyfile(p,tmp)
 os.chmod(tmp,0o750 if p.suffix in (".sh",".py") or p.parent.name=="bin" else 0o640)
 os.replace(tmp,target)
