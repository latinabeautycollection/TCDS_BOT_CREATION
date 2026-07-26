#!/usr/bin/env python3
import json,os,sys,tempfile
from pathlib import Path
s,t=map(Path,sys.argv[1:]);m=json.loads((s/'release_v1.5.0/release-manifest.json').read_text())
for e in m['files']:
 p=s/e['path'];d=t/e['path'];d.parent.mkdir(parents=True,exist_ok=True)
 fd,tmp=tempfile.mkstemp(prefix='.upgrade.',dir=d.parent)
 with os.fdopen(fd,'wb') as f:f.write(p.read_bytes());f.flush();os.fsync(f.fileno())
 os.chmod(tmp,int(e['mode'],8));os.replace(tmp,d)
