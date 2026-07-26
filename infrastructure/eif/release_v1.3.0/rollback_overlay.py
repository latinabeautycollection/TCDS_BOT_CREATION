#!/usr/bin/env python3
import hashlib,json,os,sys,tempfile
from pathlib import Path
t,b=map(Path,sys.argv[1:]);p=json.loads((b/'plan.json').read_text())
for e in reversed(p['entries']):
 r=Path(e['path'])
 if r.is_absolute() or '..' in r.parts:raise SystemExit('unsafe')
 d=(t/r).resolve();rt=t.resolve()
 if d!=rt and rt not in d.parents:raise SystemExit('escape')
 if e['action']=='CREATE':
  if d.is_file() and not d.is_symlink():d.unlink()
 else:
  blob=b/'files'/e['blob']
  if hashlib.sha256(blob.read_bytes()).hexdigest()!=e['sha256']:raise SystemExit('corrupt')
  d.parent.mkdir(parents=True,exist_ok=True);fd,tmp=tempfile.mkstemp(prefix='.rollback.',dir=d.parent)
  with os.fdopen(fd,'wb') as f:f.write(blob.read_bytes());f.flush();os.fsync(f.fileno())
  os.chmod(tmp,e['mode']);os.chown(tmp,e['uid'],e['gid']);os.replace(tmp,d)
