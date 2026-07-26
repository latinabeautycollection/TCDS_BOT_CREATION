#!/usr/bin/env python3
from __future__ import annotations
import argparse, base64, datetime as dt, fcntl, hashlib, hmac, json, os, shutil, sqlite3, stat, subprocess, sys, tempfile, uuid
from pathlib import Path
from typing import Any, Iterable

VERSION='1.0.0'
ID_RE=__import__('re').compile(r'^[A-Za-z0-9][A-Za-z0-9._:-]{0,127}$')
class BError(Exception): code=8
class Validation(BError): code=6
class Locked(BError): code=7
class Conflict(BError): code=20
class Integrity(BError): code=22
class Eligibility(BError): code=23
class Approval(BError): code=24

def utc(): return dt.datetime.now(dt.timezone.utc).isoformat(timespec='milliseconds').replace('+00:00','Z')
def canon(x): return (json.dumps(x,sort_keys=True,separators=(',',':'))+'\n').encode()
def sha(b): return hashlib.sha256(b).hexdigest()
def valid_id(v,n):
    if not isinstance(v,str) or not ID_RE.fullmatch(v): raise Validation(f'invalid {n}')
    return v

def load_json(p:Path):
    if p.is_symlink() or not p.is_file(): raise Validation(f'unsafe or missing JSON: {p}')
    try:return json.loads(p.read_text())
    except Exception as e: raise Validation(f'invalid JSON {p}: {e}')

def root_safe(root:Path):
    if not root.is_absolute() or root.is_symlink(): raise Validation('unsafe framework root')
    cur=root
    while cur!=cur.parent:
        if cur.is_symlink(): raise Validation(f'symlink path component: {cur}')
        cur=cur.parent
    return root

def beneath(parent:Path, child:Path):
    rp=parent.resolve(strict=False); rc=child.resolve(strict=False)
    if rc!=rp and rp not in rc.parents: raise Validation(f'path escapes approved root: {child}')
    return rc

def atomic(path:Path,data:bytes,mode=0o640):
    path.parent.mkdir(parents=True,exist_ok=True,mode=0o750)
    if path.is_symlink(): raise Validation(f'symlink refused: {path}')
    fd,tmp=tempfile.mkstemp(prefix='.'+path.name+'.',dir=path.parent)
    try:
        os.fchmod(fd,mode)
        with os.fdopen(fd,'wb') as f: f.write(data); f.flush(); os.fsync(f.fileno())
        os.replace(tmp,path)
        dfd=os.open(path.parent,os.O_DIRECTORY)
        try: os.fsync(dfd)
        finally: os.close(dfd)
    finally:
        if os.path.exists(tmp): os.unlink(tmp)

def db(root:Path):
    p=root/'state/backup/backup.db'; p.parent.mkdir(parents=True,exist_ok=True,mode=0o750)
    c=sqlite3.connect(p,timeout=30,isolation_level=None)
    c.execute('PRAGMA journal_mode=WAL'); c.execute('PRAGMA synchronous=FULL'); c.execute('PRAGMA foreign_keys=ON'); c.execute('PRAGMA busy_timeout=30000')
    c.executescript("""
    CREATE TABLE IF NOT EXISTS backup_sets(backup_id TEXT PRIMARY KEY,component TEXT NOT NULL,created_at TEXT NOT NULL,status TEXT NOT NULL,manifest_path TEXT NOT NULL,manifest_sha256 TEXT NOT NULL,total_bytes INTEGER NOT NULL,file_count INTEGER NOT NULL,classification TEXT NOT NULL,verified_at TEXT,rehearsed_at TEXT,exported_at TEXT,retention_until TEXT,transaction_id TEXT);
    CREATE TABLE IF NOT EXISTS restore_plans(plan_id TEXT PRIMARY KEY,backup_id TEXT NOT NULL REFERENCES backup_sets(backup_id),created_at TEXT NOT NULL,status TEXT NOT NULL,target_root TEXT NOT NULL,challenge_hash TEXT NOT NULL,plan_path TEXT NOT NULL,rehearsed_at TEXT,executed_at TEXT);
    CREATE TABLE IF NOT EXISTS events(seq INTEGER PRIMARY KEY AUTOINCREMENT,at_utc TEXT NOT NULL,kind TEXT NOT NULL,backup_id TEXT,plan_id TEXT,payload_json TEXT NOT NULL,previous_hash TEXT NOT NULL,event_hash TEXT NOT NULL);
    """)
    return c

def event(c,kind,backup_id=None,plan_id=None,payload=None):
    row=c.execute('SELECT event_hash FROM events ORDER BY seq DESC LIMIT 1').fetchone(); prev=row[0] if row else '0'*64
    body={'atUtc':utc(),'kind':kind,'backupId':backup_id,'planId':plan_id,'payload':payload or {},'previousHash':prev}
    h=sha(canon(body)); c.execute('INSERT INTO events(at_utc,kind,backup_id,plan_id,payload_json,previous_hash,event_hash) VALUES(?,?,?,?,?,?,?)',(body['atUtc'],kind,backup_id,plan_id,json.dumps(body['payload'],sort_keys=True),prev,h)); return h

def policy(root): return load_json(root/'config/backup/policy-v1.0.0.json')
def approved(root,component,p:Path):
    pol=policy(root); roots=[Path(x) for x in pol['componentRoots'].get(component,[])]
    if not roots: raise Validation(f'no backup roots registered for component {component}')
    rp=p.resolve(strict=False)
    for ar in roots:
        aa=ar.resolve(strict=False)
        if rp==aa or aa in rp.parents:return aa
    raise Validation(f'path not approved for {component}: {p}')

def xattrs(p:Path):
    out={}
    try:
        for n in os.listxattr(p,follow_symlinks=False): out[n]=base64.b64encode(os.getxattr(p,n,follow_symlinks=False)).decode()
    except (OSError,AttributeError): pass
    return out

def stream_blob(src:Path,dst:Path,chunk:int,max_file:int):
    st=os.lstat(src)
    if not stat.S_ISREG(st.st_mode): raise Validation(f'not regular file: {src}')
    if st.st_size>max_file: raise Validation(f'file exceeds limit: {src}')
    h=hashlib.sha256(); total=0
    fd=os.open(src,os.O_RDONLY|os.O_NOFOLLOW)
    tmpfd,tmp=tempfile.mkstemp(prefix='.blob.',dir=dst.parent)
    try:
        while True:
            b=os.read(fd,chunk)
            if not b:break
            total+=len(b)
            if total>max_file: raise Validation('file grew beyond limit')
            h.update(b); os.write(tmpfd,b)
        os.fsync(tmpfd)
    finally: os.close(fd); os.close(tmpfd)
    digest=h.hexdigest(); final=dst.parent/digest
    if final.exists(): os.unlink(tmp)
    else: os.replace(tmp,final); os.chmod(final,0o600)
    return digest,total

def sign_manifest(manifest:dict,pol:dict):
    ref=pol['security'].get('manifestHmacSecretReference')
    if ref and ref.startswith('secret://env/'):
        name=ref.split('/',3)[-1]; key=os.getenv(name)
        if key: return {'type':'HMAC-SHA256','keyReference':ref,'value':hmac.new(key.encode(),canon(manifest),hashlib.sha256).hexdigest()}
    return {'type':'SHA256_ONLY','warning':'HMAC key unavailable'}

def create(root,component,name,paths,classification,transaction_id=None):
    valid_id(component,'component'); valid_id(name,'backup name')
    pol=policy(root); store=root/'backups/blobs'; store.mkdir(parents=True,exist_ok=True,mode=0o700)
    limits=pol['storage']; free=shutil.disk_usage(root).free
    if free<limits['minimumFreeReserveBytes']: raise Eligibility('minimum free-space reserve not met')
    bid=str(uuid.uuid4()); entries=[]; total=0; files=0; seen_inodes={}; source_devices=set()
    for raw in paths:
        src=Path(raw); approved(root,component,src)
        if src.is_symlink(): raise Validation(f'symlink source refused: {src}')
        if not src.exists(): entries.append({'path':str(src),'type':'missing'}); continue
        root_dev=os.lstat(src).st_dev; source_devices.add(root_dev)
        iterator=[src]
        if src.is_dir(): iterator=[src]+sorted(src.rglob('*'))
        for p in iterator:
            if p.is_symlink(): raise Validation(f'symlink refused: {p}')
            st=os.lstat(p)
            if pol['security']['stayOnFilesystem'] and st.st_dev!=root_dev: raise Validation(f'filesystem crossing refused: {p}')
            meta={'path':str(p),'uid':st.st_uid,'gid':st.st_gid,'mode':stat.S_IMODE(st.st_mode),'mtimeNs':st.st_mtime_ns,'xattrs':xattrs(p)}
            if stat.S_ISDIR(st.st_mode): meta['type']='directory'
            elif stat.S_ISREG(st.st_mode):
                files+=1
                if files>limits['maxFiles']: raise Validation('maximum file count exceeded')
                inode=(st.st_dev,st.st_ino)
                if st.st_nlink>1 and inode in seen_inodes:
                    meta.update({'type':'hardlink','linkTarget':seen_inodes[inode]})
                else:
                    dg,size=stream_blob(p,store/('x'),limits['chunkBytes'],limits['maxFileBytes']); total+=size
                    if total>limits['maxBackupBytes']: raise Validation('maximum backup size exceeded')
                    meta.update({'type':'file','sha256':dg,'size':size,'blob':dg}); seen_inodes[inode]=str(p)
            else: raise Validation(f'special file refused: {p}')
            entries.append(meta)
    manifest={'schemaVersion':'1.0','backupId':bid,'name':name,'component':component,'createdAtUtc':utc(),'classification':classification,'transactionId':transaction_id,'sourceDevices':sorted(source_devices),'entries':entries,'fileCount':files,'totalBytes':total,'engineVersion':VERSION}
    manifest['contentHash']=sha(canon(manifest)); manifest['authentication']=sign_manifest(manifest,pol)
    setdir=root/'backups/sets'/bid; setdir.mkdir(parents=True,mode=0o700)
    mp=setdir/'manifest.json'; atomic(mp,canon(manifest),0o600)
    retention=(dt.datetime.now(dt.timezone.utc)+dt.timedelta(days=pol['retention']['defaultDays'])).isoformat().replace('+00:00','Z')
    c=db(root)
    try:
        c.execute('BEGIN IMMEDIATE'); c.execute('INSERT INTO backup_sets VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?,?)',(bid,component,manifest['createdAtUtc'],'CREATED',str(mp),sha(mp.read_bytes()),total,files,classification,None,None,None,retention,transaction_id)); event(c,'BACKUP_CREATED',bid,payload={'component':component,'contentHash':manifest['contentHash']}); c.execute('COMMIT')
    except: c.execute('ROLLBACK'); raise
    finally:c.close()
    return manifest

def verify_manifest(root,bid):
    valid_id(bid,'backup id'); c=db(root); row=c.execute('SELECT manifest_path FROM backup_sets WHERE backup_id=?',(bid,)).fetchone()
    if not row: c.close(); raise Validation('unknown backup')
    mp=Path(row[0]); m=load_json(mp); auth=m.pop('authentication'); content=m.pop('contentHash')
    if sha(canon(m))!=content: raise Integrity('manifest content hash mismatch')
    pol=policy(root)
    if auth.get('type')=='HMAC-SHA256':
        ref=auth['keyReference']; key=os.getenv(ref.split('/',3)[-1])
        test=dict(m); test['contentHash']=content
        if not key or not hmac.compare_digest(auth['value'],hmac.new(key.encode(),canon(test),hashlib.sha256).hexdigest()): raise Integrity('manifest HMAC verification failed')
    for e in m['entries']:
        if e['type']=='file':
            b=root/'backups/blobs'/e['blob']
            if b.is_symlink() or not b.is_file(): raise Integrity(f'missing blob {e["blob"]}')
            h=hashlib.sha256(); size=0
            with b.open('rb') as f:
                for chunk in iter(lambda:f.read(pol['storage']['chunkBytes']),b''):h.update(chunk);size+=len(chunk)
            if h.hexdigest()!=e['sha256'] or size!=e['size']: raise Integrity(f'blob mismatch {e["blob"]}')
    full=dict(m); full['contentHash']=content; full['authentication']=auth
    now=utc(); c.execute('BEGIN IMMEDIATE'); c.execute("UPDATE backup_sets SET status='VERIFIED',verified_at=? WHERE backup_id=?",(now,bid)); event(c,'BACKUP_VERIFIED',bid,payload={'contentHash':content}); c.execute('COMMIT'); c.close()
    return {'status':'VERIFIED','backupId':bid,'fileCount':full['fileCount'],'totalBytes':full['totalBytes'],'contentHash':content}

def make_plan(root,bid,target_root):
    valid_id(bid,'backup id'); verify_manifest(root,bid)
    c=db(root); row=c.execute('SELECT manifest_path,component FROM backup_sets WHERE backup_id=?',(bid,)).fetchone(); m=load_json(Path(row[0])); component=row[1]
    tr=Path(target_root)
    if not tr.is_absolute() or tr.is_symlink(): raise Validation('unsafe target root')
    pid=str(uuid.uuid4()); challenge=hashlib.sha256(os.urandom(32)).hexdigest()[:24]
    actions=[]
    allowed_roots=[Path(x) for x in policy(root)['componentRoots'][component]]
    for e in m['entries']:
        original=Path(e['path']); selected=None
        for ar in allowed_roots:
            try: rel=original.relative_to(ar); selected=tr/ar.relative_to('/')/rel; break
            except ValueError:continue
        if selected is None: raise Validation('manifest path outside current policy')
        actions.append({'sourcePath':str(original),'targetPath':str(selected),'type':e['type'],'sha256':e.get('sha256')})
    plan={'schemaVersion':'1.0','planId':pid,'backupId':bid,'component':component,'createdAtUtc':utc(),'targetRoot':str(tr),'actions':actions,'approvalChallenge':challenge,'status':'PLANNED'}
    pp=root/'backups/sets'/bid/f'restore-plan-{pid}.json'; atomic(pp,canon(plan),0o600)
    c.execute('BEGIN IMMEDIATE'); c.execute('INSERT INTO restore_plans(plan_id,backup_id,created_at,status,target_root,challenge_hash,plan_path) VALUES(?,?,?,?,?,?,?)',(pid,bid,plan['createdAtUtc'],'PLANNED',str(tr),sha(challenge.encode()),str(pp))); event(c,'RESTORE_PLAN_CREATED',bid,pid,{'targetRoot':str(tr)}); c.execute('COMMIT'); c.close()
    return plan

def restore_entries(root,m,target_root,dry):
    pol=policy(root); actions=[]; created_dirs=[]
    roots=[Path(x) for x in pol['componentRoots'][m['component']]]; target_root=Path(target_root)
    pathmap={}
    for e in m['entries']:
        original=Path(e['path']); target=None
        for ar in roots:
            try: target=target_root/ar.relative_to('/')/original.relative_to(ar); break
            except ValueError:continue
        if target is None: raise Validation('restore path outside allowlist')
        if target.is_symlink(): raise Validation(f'symlink target refused: {target}')
        pathmap[str(original)]=target
        actions.append({'type':e['type'],'target':str(target)})
        if dry: continue
        if e['type']=='directory': target.mkdir(parents=True,exist_ok=True,mode=e['mode']); os.chmod(target,e['mode']); os.chown(target,e['uid'],e['gid']); created_dirs.append(target)
        elif e['type']=='file':
            target.parent.mkdir(parents=True,exist_ok=True); blob=root/'backups/blobs'/e['blob']; fd,tmp=tempfile.mkstemp(prefix='.'+target.name+'.restore.',dir=target.parent)
            try:
                h=hashlib.sha256()
                with os.fdopen(fd,'wb') as out,blob.open('rb') as inp:
                    for chunk in iter(lambda:inp.read(pol['storage']['chunkBytes']),b''): out.write(chunk);h.update(chunk)
                    out.flush();os.fsync(out.fileno())
                if h.hexdigest()!=e['sha256']: raise Integrity('blob changed during restore')
                os.chmod(tmp,e['mode']); os.chown(tmp,e['uid'],e['gid'])
                for n,v in e.get('xattrs',{}).items(): os.setxattr(tmp,n,base64.b64decode(v),follow_symlinks=False)
                os.replace(tmp,target); os.utime(target,ns=(e['mtimeNs'],e['mtimeNs']),follow_symlinks=False)
            finally:
                if os.path.exists(tmp):os.unlink(tmp)
        elif e['type']=='hardlink':
            target.parent.mkdir(parents=True,exist_ok=True); source=pathmap.get(e['linkTarget'])
            if not source or not source.exists(): raise Integrity('hardlink source unavailable')
            if target.exists(): target.unlink()
            os.link(source,target,follow_symlinks=False)
        elif e['type']=='missing': pass
    return actions

def rehearse(root,plan_id):
    valid_id(plan_id,'plan id'); c=db(root); row=c.execute('SELECT backup_id,plan_path FROM restore_plans WHERE plan_id=?',(plan_id,)).fetchone()
    if not row:c.close();raise Validation('unknown plan')
    bid,pp=row; plan=load_json(Path(pp)); m=load_json(root/'backups/sets'/bid/'manifest.json')
    rehearsal=root/'backups/rehearsals'/plan_id
    if rehearsal.exists(): shutil.rmtree(rehearsal)
    rehearsal.mkdir(parents=True,mode=0o700)
    restore_entries(root,m,rehearsal,False)
    # verify restored regular files
    for e in m['entries']:
        if e['type']!='file':continue
        target=None
        for ar in [Path(x) for x in policy(root)['componentRoots'][m['component']]]:
            try: target=rehearsal/ar.relative_to('/')/Path(e['path']).relative_to(ar);break
            except ValueError:continue
        h=hashlib.sha256(target.read_bytes()).hexdigest()
        if h!=e['sha256']: raise Integrity(f'rehearsal mismatch: {target}')
    now=utc(); c.execute('BEGIN IMMEDIATE');c.execute("UPDATE restore_plans SET status='REHEARSED',rehearsed_at=? WHERE plan_id=?",(now,plan_id));c.execute("UPDATE backup_sets SET rehearsed_at=? WHERE backup_id=?",(now,bid));event(c,'RESTORE_REHEARSED',bid,plan_id,{'rehearsalRoot':str(rehearsal)});c.execute('COMMIT');c.close()
    return {'status':'REHEARSED','planId':plan_id,'backupId':bid,'rehearsalRoot':str(rehearsal)}

def eligibility(root,plan_id):
    valid_id(plan_id,'plan id'); c=db(root); row=c.execute('SELECT p.backup_id,p.status,b.status,b.verified_at,p.rehearsed_at FROM restore_plans p JOIN backup_sets b ON b.backup_id=p.backup_id WHERE p.plan_id=?',(plan_id,)).fetchone();c.close()
    if not row:raise Validation('unknown plan')
    reasons=[]
    if row[2]!='VERIFIED':reasons.append('backup_not_verified')
    if policy(root)['restore']['requireRehearsal'] and not row[4]:reasons.append('restore_not_rehearsed')
    return {'eligible':not reasons,'planId':plan_id,'backupId':row[0],'reasons':reasons}

def execute_restore(root,plan_id,challenge):
    eligible=eligibility(root,plan_id)
    if not eligible['eligible']:raise Eligibility(','.join(eligible['reasons']))
    c=db(root); row=c.execute('SELECT backup_id,challenge_hash,plan_path FROM restore_plans WHERE plan_id=?',(plan_id,)).fetchone(); bid,ch,pp=row
    if not hmac.compare_digest(ch,sha(challenge.encode())):c.close();raise Approval('approval challenge mismatch')
    plan=load_json(Path(pp));m=load_json(root/'backups/sets'/bid/'manifest.json')
    restore_entries(root,m,plan['targetRoot'],False)
    now=utc();c.execute('BEGIN IMMEDIATE');c.execute("UPDATE restore_plans SET status='EXECUTED',executed_at=? WHERE plan_id=?",(now,plan_id));event(c,'RESTORE_EXECUTED',bid,plan_id,{'targetRoot':plan['targetRoot']});c.execute('COMMIT');c.close()
    return {'status':'RESTORED','planId':plan_id,'backupId':bid}

def export_file(root,bid,destination):
    verify_manifest(root,bid); dest=Path(destination)
    if not dest.is_absolute() or dest.is_symlink():raise Validation('unsafe export destination')
    out=dest/bid;out.mkdir(parents=True,exist_ok=False,mode=0o700)
    m=load_json(root/'backups/sets'/bid/'manifest.json'); shutil.copy2(root/'backups/sets'/bid/'manifest.json',out/'manifest.json')
    (out/'blobs').mkdir(mode=0o700)
    for e in m['entries']:
        if e['type']=='file':
            src=root/'backups/blobs'/e['blob']; dst=out/'blobs'/e['blob']; os.link(src,dst) if src.stat().st_dev==out.stat().st_dev else shutil.copy2(src,dst)
    marker={'backupId':bid,'exportedAtUtc':utc(),'manifestSha256':sha((out/'manifest.json').read_bytes()),'immutableRetentionRequired':True};atomic(out/'EXPORT-MANIFEST.json',canon(marker),0o600)
    c=db(root);c.execute('BEGIN IMMEDIATE');c.execute('UPDATE backup_sets SET exported_at=? WHERE backup_id=?',(marker['exportedAtUtc'],bid));event(c,'BACKUP_EXPORTED',bid,payload={'destination':str(out)});c.execute('COMMIT');c.close()
    return {'status':'EXPORTED','destination':str(out),**marker}

def prune(root,dry):
    pol=policy(root);c=db(root);now=utc(); rows=c.execute('SELECT backup_id,component,status,retention_until FROM backup_sets ORDER BY created_at DESC').fetchall(); protected=set(); counts={}
    for bid,comp,status,until in rows:
        counts[comp]=counts.get(comp,0)+1
        if counts[comp]<=pol['retention']['protectLatestPerComponent']:protected.add(bid)
    deleted=[]
    for bid,comp,status,until in rows:
        if bid in protected or until>=now or (status!='VERIFIED' and not pol['retention']['deleteUnverified']):continue
        deleted.append(bid)
        if not dry:
            shutil.rmtree(root/'backups/sets'/bid,ignore_errors=False);c.execute('DELETE FROM backup_sets WHERE backup_id=?',(bid,));event(c,'BACKUP_PRUNED',bid)
    if not dry:c.commit()
    c.close();return {'status':'DRY_RUN' if dry else 'PRUNED','backupIds':deleted}

def verify_events(root):
    c=db(root); rows=c.execute('SELECT seq,at_utc,kind,backup_id,plan_id,payload_json,previous_hash,event_hash FROM events ORDER BY seq').fetchall();prev='0'*64
    for seq,at,kind,bid,pid,payload,ph,eh in rows:
        body={'atUtc':at,'kind':kind,'backupId':bid,'planId':pid,'payload':json.loads(payload),'previousHash':ph}
        if ph!=prev or sha(canon(body))!=eh:raise Integrity(f'event chain failure at {seq}')
        prev=eh
    c.close();return {'status':'PASS','entries':len(rows),'lastHash':prev}

def main():
    a=argparse.ArgumentParser();a.add_argument('--root',required=True,type=Path);s=a.add_subparsers(dest='cmd',required=True)
    p=s.add_parser('create');p.add_argument('component');p.add_argument('name');p.add_argument('paths',nargs='+');p.add_argument('--classification',default='internal');p.add_argument('--transaction-id')
    p=s.add_parser('verify');p.add_argument('backup_id')
    p=s.add_parser('plan');p.add_argument('backup_id');p.add_argument('target_root')
    p=s.add_parser('rehearse');p.add_argument('plan_id')
    p=s.add_parser('eligibility');p.add_argument('plan_id')
    p=s.add_parser('restore');p.add_argument('plan_id');p.add_argument('--approval-challenge',required=True)
    p=s.add_parser('export-file');p.add_argument('backup_id');p.add_argument('destination')
    p=s.add_parser('prune');p.add_argument('--dry-run',action='store_true')
    s.add_parser('verify-events')
    x=a.parse_args();root=root_safe(x.root)
    try:
        if x.cmd=='create':r=create(root,x.component,x.name,x.paths,x.classification,x.transaction_id)
        elif x.cmd=='verify':r=verify_manifest(root,x.backup_id)
        elif x.cmd=='plan':r=make_plan(root,x.backup_id,x.target_root)
        elif x.cmd=='rehearse':r=rehearse(root,x.plan_id)
        elif x.cmd=='eligibility':r=eligibility(root,x.plan_id)
        elif x.cmd=='restore':r=execute_restore(root,x.plan_id,x.approval_challenge)
        elif x.cmd=='export-file':r=export_file(root,x.backup_id,x.destination)
        elif x.cmd=='prune':r=prune(root,x.dry_run)
        else:r=verify_events(root)
        print(json.dumps(r,indent=2,sort_keys=True))
    except BError as e:
        print(json.dumps({'status':'ERROR','error':type(e).__name__,'message':str(e)}),file=sys.stderr);raise SystemExit(e.code)
if __name__=='__main__':main()
