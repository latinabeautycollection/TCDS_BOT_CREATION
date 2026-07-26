#!/usr/bin/env python3
import hashlib,json,os,stat,sys
from pathlib import Path
root=Path(sys.argv[1])
policy=json.loads((root/"config/execution/policy-v2.json").read_text())
manifest={}
for name,cmd in policy["commands"].items():
    p=Path(cmd["executable"])
    if cmd.get("optional") and not p.exists():continue
    st=os.lstat(p)
    if stat.S_ISLNK(st.st_mode) or not stat.S_ISREG(st.st_mode):raise SystemExit(f"unsafe executable: {p}")
    h=hashlib.sha256(p.read_bytes()).hexdigest()
    manifest[str(p)]={"sha256":h,"inode":st.st_ino,"device":st.st_dev,"uid":st.st_uid,"gid":st.st_gid,"mode":oct(stat.S_IMODE(st.st_mode))}
tmp=root/"config/execution/trust-manifest.json.tmp"
tmp.write_text(json.dumps(manifest,indent=2)+"\n")
os.chmod(tmp,0o640);os.replace(tmp,root/"config/execution/trust-manifest.json")
