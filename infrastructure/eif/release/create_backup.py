#!/usr/bin/env python3
import hashlib,json,os,shutil,stat,sys
from pathlib import Path
src=Path(sys.argv[1]);dst=Path(sys.argv[2]);entries=[]
for p in src.rglob("*"):
 rel=p.relative_to(src)
 if str(rel).startswith(("backups/","logs/","events/","state/executions/")):continue
 st=os.lstat(p)
 if stat.S_ISLNK(st.st_mode) or not (stat.S_ISREG(st.st_mode) or stat.S_ISDIR(st.st_mode)):
  raise SystemExit(f"unsafe backup object: {p}")
 if p.is_dir():continue
 out=dst/"files"/rel;out.parent.mkdir(parents=True,exist_ok=True)
 shutil.copy2(p,out)
 h=hashlib.sha256(out.read_bytes()).hexdigest()
 entries.append({"path":str(rel),"sha256":h,"uid":st.st_uid,"gid":st.st_gid,"mode":stat.S_IMODE(st.st_mode)})
for e in entries:
 p=dst/"files"/e["path"]
 if hashlib.sha256(p.read_bytes()).hexdigest()!=e["sha256"]:raise SystemExit("backup verification failed")
manifest={"schemaVersion":"1.0","entries":entries}
tmp=dst/"backup-manifest.json.tmp";tmp.write_text(json.dumps(manifest,indent=2)+"\n");os.chmod(tmp,0o640);os.replace(tmp,dst/"backup-manifest.json")
print("backup verified")
