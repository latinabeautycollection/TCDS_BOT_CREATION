#!/usr/bin/env python3
import hashlib,json,shutil,stat,sys
from pathlib import Path
s,t,b=map(Path,sys.argv[1:]); files=[]
for p in sorted(s.rglob('*')):
 if not p.is_file() or p.is_symlink(): continue
 rel=str(p.relative_to(s))
 if rel.startswith(('state/','logs/','events/','backups/')) or rel in {'release/manifest-v0.9.0.json'}: continue
 dst=t/rel; action='REPLACE' if dst.exists() else 'CREATE'; e={'path':rel,'action':action,'newSha256':hashlib.sha256(p.read_bytes()).hexdigest(),'mode':stat.S_IMODE(p.stat().st_mode)}
 if action=='REPLACE':
  key=hashlib.sha256(rel.encode()).hexdigest(); blob=b/'files'/key; shutil.copy2(dst,blob); e.update({'backupBlob':key,'oldSha256':hashlib.sha256(blob.read_bytes()).hexdigest(),'oldMode':stat.S_IMODE(dst.stat().st_mode)})
 files.append(e)
(b/'plan.json').write_text(json.dumps({'schemaVersion':'1.0','files':files},indent=2)+'\n')
