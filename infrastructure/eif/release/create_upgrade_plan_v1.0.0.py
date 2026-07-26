#!/usr/bin/env python3
import hashlib,json,shutil,stat,sys,os,datetime
from pathlib import Path
s,t,b=map(Path,sys.argv[1:]);items=[]
for p in sorted(s.rglob('*')):
 if not p.is_file() or p.is_symlink():continue
 rel=p.relative_to(s); rs=str(rel)
 if rs in {'install-milestone-1b6.sh','rollback-milestone-1b6.sh','release/manifest-v1.0.0.json'} or rs.startswith(('state/','backups/sets/','backups/blobs/','backups/exports/','backups/rehearsals/','logs/','events/')):continue
 dst=t/rel; action='REPLACE' if dst.exists() else 'CREATE';e={'path':rs,'action':action,'newSha256':hashlib.sha256(p.read_bytes()).hexdigest(),'newMode':stat.S_IMODE(p.stat().st_mode)}
 if action=='REPLACE':
  if dst.is_symlink() or not dst.is_file():raise SystemExit('unsafe replacement: '+str(dst))
  key=hashlib.sha256(rs.encode()).hexdigest();blob=b/'files'/key;shutil.copy2(dst,blob);st=dst.stat();e.update({'backupBlob':key,'oldSha256':hashlib.sha256(blob.read_bytes()).hexdigest(),'oldMode':stat.S_IMODE(st.st_mode),'oldUid':st.st_uid,'oldGid':st.st_gid})
 items.append(e)
plan={'schemaVersion':'1.0','version':'1.0.0','createdAtUtc':datetime.datetime.now(datetime.timezone.utc).isoformat(),'targetRoot':str(t),'files':items};raw=json.dumps(plan,indent=2)+'\n';(b/'plan.json').write_text(raw);(b/'plan.sha256').write_text(hashlib.sha256(raw.encode()).hexdigest()+'\n');os.sync()
