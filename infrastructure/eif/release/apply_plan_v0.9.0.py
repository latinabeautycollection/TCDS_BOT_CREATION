#!/usr/bin/env python3
import hashlib,json,os,shutil,sys,tempfile
from pathlib import Path
s,t,plan,mode=Path(sys.argv[1]),Path(sys.argv[2]),Path(sys.argv[3]),sys.argv[4]; d=json.loads(plan.read_text()); b=plan.parent
for e in d['files']:
 rel=Path(e['path'])
 if rel.is_absolute() or '..' in rel.parts: raise SystemExit('unsafe path')
 dst=t/rel
 if mode=='apply':
  src=s/rel; dst.parent.mkdir(parents=True,exist_ok=True); fd,tmp=tempfile.mkstemp(prefix='.apply.',dir=dst.parent)
  with os.fdopen(fd,'wb') as f:f.write(src.read_bytes());f.flush();os.fsync(f.fileno())
  os.chmod(tmp,e['mode']);os.replace(tmp,dst)
 else:
  if e['action']=='CREATE':
   if dst.exists() and dst.is_file():dst.unlink()
  else:
   blob=b/'files'/e['backupBlob']
   if hashlib.sha256(blob.read_bytes()).hexdigest()!=e['oldSha256']:raise SystemExit('backup corrupt')
   dst.parent.mkdir(parents=True,exist_ok=True); fd,tmp=tempfile.mkstemp(prefix='.restore.',dir=dst.parent)
   with os.fdopen(fd,'wb') as f:f.write(blob.read_bytes());f.flush();os.fsync(f.fileno())
   os.chmod(tmp,e['oldMode']);os.replace(tmp,dst)
