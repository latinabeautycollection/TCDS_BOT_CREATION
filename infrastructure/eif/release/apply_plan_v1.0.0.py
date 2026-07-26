#!/usr/bin/env python3
import hashlib,json,os,sys,tempfile
from pathlib import Path
s,t,p,mode=Path(sys.argv[1]),Path(sys.argv[2]),Path(sys.argv[3]),sys.argv[4];d=json.loads(p.read_text());b=p.parent;rt=t.resolve()
for e in d['files']:
 rel=Path(e['path'])
 if rel.is_absolute() or '..' in rel.parts:raise SystemExit('unsafe path')
 dst=t/rel;rd=dst.resolve(strict=False)
 if rd!=rt and rt not in rd.parents:raise SystemExit('path escape')
 if dst.is_symlink():raise SystemExit('symlink collision')
 if mode=='apply':src=s/rel;data=src.read_bytes();expected=e['newSha256'];perm=e['newMode']
 elif e['action']=='CREATE':
  if dst.exists() and dst.is_file():dst.unlink()
  continue
 else:data=(b/'files'/e['backupBlob']).read_bytes();expected=e['oldSha256'];perm=e['oldMode']
 if hashlib.sha256(data).hexdigest()!=expected:raise SystemExit('source hash mismatch')
 dst.parent.mkdir(parents=True,exist_ok=True);fd,tmp=tempfile.mkstemp(prefix='.eif.',dir=dst.parent)
 with os.fdopen(fd,'wb') as f:f.write(data);f.flush();os.fsync(f.fileno())
 os.chmod(tmp,perm)
 if mode=='rollback' and e['action']=='REPLACE':os.chown(tmp,e['oldUid'],e['oldGid'])
 os.replace(tmp,dst)
