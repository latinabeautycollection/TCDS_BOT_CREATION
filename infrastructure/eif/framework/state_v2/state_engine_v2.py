#!/usr/bin/env python3
from __future__ import annotations
import argparse, contextlib, datetime as dt, hashlib, hmac, json, os, shutil, socket, sqlite3, stat, sys, tempfile, time, uuid
from pathlib import Path
VERSION='0.9.0'
TX={'NEW':{'PREPARED','FAILED'},'PREPARED':{'APPLYING','FAILED','ROLLBACK_PENDING'},'APPLYING':{'VALIDATING','FAILED','ROLLBACK_PENDING'},'VALIDATING':{'COMMITTING','FAILED','ROLLBACK_PENDING'},'COMMITTING':{'COMMITTED','FAILED','RECOVERY_REQUIRED'},'FAILED':{'ROLLBACK_PENDING','ABANDONED','RECOVERY_REQUIRED'},'ROLLBACK_PENDING':{'ROLLING_BACK','ABANDONED'},'ROLLING_BACK':{'ROLLED_BACK','RECOVERY_REQUIRED'},'ROLLED_BACK':{'PREPARED','ABANDONED'},'RECOVERY_REQUIRED':{'ROLLBACK_PENDING','ABANDONED'},'COMMITTED':set(),'ABANDONED':set()}
ACTIVE={'APPLYING','VALIDATING','COMMITTING','ROLLING_BACK'}
class X(Exception): code=8
class V(X): code=6
class C(X): code=20
class Q(X): code=21
class R(X): code=19
def utc(): return dt.datetime.now(dt.timezone.utc).isoformat(timespec='milliseconds').replace('+00:00','Z')
def canon(x): return json.dumps(x,sort_keys=True,separators=(',',':')).encode()
def sha(b): return hashlib.sha256(b).hexdigest()
def ident(v,n):
 import re
 if not isinstance(v,str) or not re.fullmatch(r'[A-Za-z0-9][A-Za-z0-9._:-]{0,127}',v): raise V('invalid '+n)
 return v
def rootok(p):
 if not p.is_absolute() or p.is_symlink(): raise V('unsafe root')
 cur=p
 while cur!=cur.parent:
  if cur.is_symlink(): raise V('symlink path component')
  cur=cur.parent
 return p
def config(root): return json.loads((root/'config/state/state-v0.9.0.json').read_text())
def db(root):
 p=root/'state/database/state-v0.9.0.sqlite3'; p.parent.mkdir(parents=True,exist_ok=True,mode=0o750)
 con=sqlite3.connect(p,timeout=30,isolation_level=None); con.row_factory=sqlite3.Row
 con.execute('PRAGMA journal_mode=WAL'); con.execute('PRAGMA synchronous=FULL'); con.execute('PRAGMA foreign_keys=ON'); con.execute('PRAGMA busy_timeout=30000')
 con.executescript('''CREATE TABLE IF NOT EXISTS transactions(id TEXT PRIMARY KEY, component TEXT NOT NULL, operation TEXT NOT NULL, change_id TEXT NOT NULL, idem_digest TEXT UNIQUE NOT NULL, request_digest TEXT NOT NULL, state TEXT NOT NULL, version INTEGER NOT NULL, document TEXT NOT NULL, lease_id TEXT, lease_host TEXT, lease_pid INTEGER, lease_boot_id TEXT, lease_expires_at REAL, heartbeat_at REAL, created_at TEXT NOT NULL, updated_at TEXT NOT NULL); CREATE TABLE IF NOT EXISTS events(sequence INTEGER PRIMARY KEY AUTOINCREMENT, tx_id TEXT, kind TEXT NOT NULL, payload TEXT NOT NULL, previous_hash TEXT NOT NULL, entry_hash TEXT NOT NULL, created_at TEXT NOT NULL); CREATE TABLE IF NOT EXISTS checkpoints(tx_id TEXT NOT NULL, name TEXT NOT NULL, manifest_path TEXT NOT NULL, manifest_hash TEXT NOT NULL, verified INTEGER NOT NULL, created_at TEXT NOT NULL, PRIMARY KEY(tx_id,name), FOREIGN KEY(tx_id) REFERENCES transactions(id)); CREATE TABLE IF NOT EXISTS gates(tx_id TEXT NOT NULL, gate TEXT NOT NULL, status TEXT NOT NULL, evidence_id TEXT, detail TEXT, updated_at TEXT NOT NULL, PRIMARY KEY(tx_id,gate), FOREIGN KEY(tx_id) REFERENCES transactions(id)); CREATE TABLE IF NOT EXISTS sagas(id TEXT PRIMARY KEY, state TEXT NOT NULL, version INTEGER NOT NULL, document TEXT NOT NULL, created_at TEXT NOT NULL, updated_at TEXT NOT NULL);''')
 return con
def event(con,tx,kind,payload):
 row=con.execute('SELECT entry_hash FROM events ORDER BY sequence DESC LIMIT 1').fetchone(); prev=row[0] if row else '0'*64
 body={'txId':tx,'kind':kind,'payload':payload,'previousHash':prev,'createdAtUtc':utc()}; eh=sha(canon(body))
 con.execute('INSERT INTO events(tx_id,kind,payload,previous_hash,entry_hash,created_at) VALUES(?,?,?,?,?,?)',(tx,kind,json.dumps(payload,separators=(',',':')),prev,eh,body['createdAtUtc']))
 return eh
def gettx(con,tid):
 row=con.execute('SELECT document FROM transactions WHERE id=?',(tid,)).fetchone()
 if not row: raise V('transaction not found')
 return json.loads(row[0])
def required_gates(component,target):
 if target=='APPLYING': return ['checkpoint_verified','change_plan_approved','execution_authorized','dependencies_healthy']
 if target=='COMMITTING':
  base=['validator_passed','health_passed','rollback_eligible']
  if component=='envoy': return base+['envoy_config_valid','envoy_canary_healthy','envoy_admin_ready','envoy_inventory_match','envoy_post_cutover_healthy']
  if component=='suricata': return base+['suricata_config_valid','suricata_rules_valid','suricata_eve_healthy','suricata_packet_drop_acceptable','suricata_ja_features_verified']
  if component=='pqp': return base+['pqp_ready','clock_sync_healthy','evidence_complete','correlation_confidence_pass','evidence_manifest_sealed','evidence_export_verified']
  return base
 return []
def begin(root,component,operation,change,key,rollback,correlation):
 for v,n in [(component,'component'),(operation,'operation'),(change,'change'),(key,'idempotency')]: ident(v,n)
 req={'component':component,'operation':operation,'changeId':change,'rollbackStrategy':rollback,'correlation':correlation}; rd=sha(canon(req)); kd=sha(key.encode()); con=db(root)
 with con:
  old=con.execute('SELECT id,request_digest FROM transactions WHERE idem_digest=?',(kd,)).fetchone()
  if old:
   if old['request_digest']!=rd: raise C('IDEMPOTENCY_CONFLICT')
   return gettx(con,old['id'])
  tid=str(uuid.uuid4()); now=utc(); doc={'schemaVersion':'2.0','transactionId':tid,**req,'state':'NEW','version':0,'checkpoints':[],'gates':{},'history':[],'createdAtUtc':now,'updatedAtUtc':now}
  con.execute('INSERT INTO transactions VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)',(tid,component,operation,change,kd,rd,'NEW',0,json.dumps(doc,separators=(',',':')),None,None,None,None,None,None,now,now)); event(con,tid,'TRANSACTION_CREATED',req)
 return doc
def gate(root,tid,name,status,evidence,detail):
 ident(name,'gate');
 if status not in {'PASS','FAIL','PENDING','WAIVED'}: raise V('invalid gate status')
 con=db(root)
 with con:
  d=gettx(con,tid); now=utc(); con.execute('INSERT INTO gates VALUES(?,?,?,?,?,?) ON CONFLICT(tx_id,gate) DO UPDATE SET status=excluded.status,evidence_id=excluded.evidence_id,detail=excluded.detail,updated_at=excluded.updated_at',(tid,name,status,evidence,detail,now)); d['gates'][name]={'status':status,'evidenceId':evidence,'detail':detail,'updatedAtUtc':now}; d['version']+=1; d['updatedAtUtc']=now; con.execute('UPDATE transactions SET version=?,document=?,updated_at=? WHERE id=?',(d['version'],json.dumps(d,separators=(',',':')),now,tid)); event(con,tid,'GATE_UPDATED',{'gate':name,'status':status,'evidenceId':evidence})
 return d
def transition(root,tid,target,reason,expected):
 if target not in TX: raise V('invalid target')
 con=db(root)
 with con:
  d=gettx(con,tid)
  if expected is not None and d['version']!=expected: raise C('VERSION_CONFLICT')
  cur=d['state']
  if target not in TX[cur]: raise C(f'invalid transition {cur}->{target}')
  missing=[g for g in required_gates(d['component'],target) if d['gates'].get(g,{}).get('status') not in {'PASS','WAIVED'}]
  if missing: raise C('GATE_FAILURE:'+','.join(missing))
  prepare={'from':cur,'to':target,'reason':reason,'expectedVersion':d['version']}; event(con,tid,'STATE_PREPARE',prepare)
  now=utc(); d['state']=target; d['version']+=1; d['updatedAtUtc']=now; d['history'].append({**prepare,'committedAtUtc':now}); con.execute('UPDATE transactions SET state=?,version=?,document=?,updated_at=? WHERE id=?',(target,d['version'],json.dumps(d,separators=(',',':')),now,tid)); event(con,tid,'STATE_COMMIT',{'state':target,'version':d['version']})
 return d
def lease(root,tid,seconds,receipt):
 cfg=config(root); seconds=min(max(seconds,10),cfg['leases']['maxSeconds']); con=db(root)
 with con:
  d=gettx(con,tid); lid=str(uuid.uuid4()); now=time.time(); boot=Path('/proc/sys/kernel/random/boot_id').read_text().strip() if Path('/proc/sys/kernel/random/boot_id').exists() else 'unknown'; exp=now+seconds; con.execute('UPDATE transactions SET lease_id=?,lease_host=?,lease_pid=?,lease_boot_id=?,lease_expires_at=?,heartbeat_at=? WHERE id=?',(lid,socket.gethostname(),os.getpid(),boot,exp,now,tid)); event(con,tid,'LEASE_ACQUIRED',{'leaseId':lid,'expiresAtEpoch':exp,'executionReceiptId':receipt})
 return {'leaseId':lid,'expiresAtEpoch':exp}
def heartbeat(root,tid,lid,seconds):
 con=db(root); now=time.time()
 with con:
  row=con.execute('SELECT lease_id FROM transactions WHERE id=?',(tid,)).fetchone()
  if not row or row[0]!=lid: raise C('LEASE_CONFLICT')
  con.execute('UPDATE transactions SET heartbeat_at=?,lease_expires_at=? WHERE id=?',(now,now+seconds,tid)); event(con,tid,'LEASE_HEARTBEAT',{'leaseId':lid})
 return {'status':'PASS'}
def allowroots(root,component):
 p=root/'config/components/checkpoint-allowlists.json'; doc=json.loads(p.read_text()); return [Path(x) for x in doc.get(component,[])]
def allowed(root,component,p):
 rp=p.resolve(strict=False)
 for a in allowroots(root,component):
  ra=a.resolve(strict=False)
  if rp==ra or ra in rp.parents:return True
 return False
def stream_copy(src,dst,maxbytes):
 total=0; h=hashlib.sha256();
 with src.open('rb') as i,dst.open('xb') as o:
  while True:
   b=i.read(1024*1024)
   if not b:break
   total+=len(b)
   if total>maxbytes: raise Q('MAX_FILE_BYTES')
   h.update(b); o.write(b)
  o.flush(); os.fsync(o.fileno())
 return total,h.hexdigest()
def checkpoint(root,tid,name,paths,expected):
 ident(name,'checkpoint'); con=db(root); cfg=config(root)
 with con:
  d=gettx(con,tid)
  if expected is not None and d['version']!=expected: raise C('VERSION_CONFLICT')
  base=root/'state/checkpoints-v2'/tid/name
  if base.exists(): raise C('checkpoint exists')
  base.mkdir(parents=True,mode=0o750); entries=[]; total=0; count=0; device=None
  for raw in paths:
   top=Path(raw)
   if not top.is_absolute() or not allowed(root,d['component'],top): raise V('checkpoint path outside component allowlist')
   candidates=[top]
   if top.is_dir(): candidates=[top]+sorted(x for x in top.rglob('*'))
   for p in candidates:
    if p.is_symlink(): raise Q('symlink refused')
    st=p.lstat(); device=device if device is not None else st.st_dev
    if st.st_dev!=device: raise Q('filesystem boundary crossed')
    rel=str(p); e={'source':rel,'mode':stat.S_IMODE(st.st_mode),'uid':st.st_uid,'gid':st.st_gid,'mtimeNs':st.st_mtime_ns}
    if p.is_dir(): e['type']='directory'
    elif p.is_file():
     count+=1
     if count>cfg['checkpoints']['maxFiles']: raise Q('MAX_FILES')
     blob=base/(sha(rel.encode())+'.blob'); size,dig=stream_copy(p,blob,cfg['checkpoints']['maxFileBytes']); total+=size
     if total>cfg['checkpoints']['maxCheckpointBytes']: raise Q('MAX_CHECKPOINT_BYTES')
     e.update({'type':'file','blob':blob.name,'size':size,'sha256':dig})
    else: raise Q('special file refused')
    entries.append(e)
  free=shutil.disk_usage(base).free
  if free<cfg['checkpoints']['minimumFreeBytes']: raise Q('LOW_DISK_RESERVE')
  m={'schemaVersion':'2.0','transactionId':tid,'component':d['component'],'name':name,'entries':entries,'totalBytes':total,'fileCount':count,'createdAtUtc':utc()}; m['manifestHash']=sha(canon(m)); (base/'manifest.json').write_text(json.dumps(m,indent=2)+'\n'); os.chmod(base/'manifest.json',0o640)
  con.execute('INSERT INTO checkpoints VALUES(?,?,?,?,?,?)',(tid,name,str(base/'manifest.json'),m['manifestHash'],1,utc())); d['checkpoints'].append({'name':name,'manifestHash':m['manifestHash'],'verified':True}); d['version']+=1; d['updatedAtUtc']=utc(); con.execute('UPDATE transactions SET version=?,document=?,updated_at=? WHERE id=?',(d['version'],json.dumps(d,separators=(',',':')),d['updatedAtUtc'],tid)); event(con,tid,'CHECKPOINT_COMMITTED',{'name':name,'manifestHash':m['manifestHash'],'totalBytes':total})
 return m
def reconcile(root):
 con=db(root); now=time.time(); out=[]
 with con:
  rows=con.execute("SELECT id,state,lease_expires_at,lease_pid,lease_host,lease_boot_id FROM transactions WHERE state IN ('APPLYING','VALIDATING','COMMITTING','ROLLING_BACK')").fetchall()
  boot=Path('/proc/sys/kernel/random/boot_id').read_text().strip() if Path('/proc/sys/kernel/random/boot_id').exists() else 'unknown'
  for r in rows:
   alive=False
   if r['lease_host']==socket.gethostname() and r['lease_boot_id']==boot and r['lease_pid']:
    try: os.kill(r['lease_pid'],0); alive=True
    except OSError: pass
   if alive and r['lease_expires_at'] and r['lease_expires_at']>now: continue
   d=gettx(con,r['id']); d['state']='RECOVERY_REQUIRED'; d['version']+=1; d['updatedAtUtc']=utc(); con.execute('UPDATE transactions SET state=?,version=?,document=?,updated_at=? WHERE id=?',('RECOVERY_REQUIRED',d['version'],json.dumps(d,separators=(',',':')),d['updatedAtUtc'],r['id'])); event(con,r['id'],'RECOVERY_REQUIRED',{'reason':'expired_or_dead_lease'}); out.append(r['id'])
 return {'status':'PASS','reconciled':out}
def verify(root):
 con=db(root); prev='0'*64; count=0
 for r in con.execute('SELECT sequence,tx_id,kind,payload,previous_hash,entry_hash,created_at FROM events ORDER BY sequence'):
  body={'txId':r['tx_id'],'kind':r['kind'],'payload':json.loads(r['payload']),'previousHash':r['previous_hash'],'createdAtUtc':r['created_at']}
  if r['previous_hash']!=prev or sha(canon(body))!=r['entry_hash']: raise V('event chain failure')
  prev=r['entry_hash']; count=r['sequence']
 return {'status':'PASS','entries':count,'lastHash':prev}
def saga(root,sid,steps):
 ident(sid,'saga'); con=db(root); now=utc(); doc={'schemaVersion':'1.0','sagaId':sid,'state':'NEW','version':0,'steps':steps,'createdAtUtc':now,'updatedAtUtc':now}
 with con: con.execute('INSERT INTO sagas VALUES(?,?,?,?,?,?)',(sid,'NEW',0,json.dumps(doc,separators=(',',':')),now,now)); event(con,None,'SAGA_CREATED',{'sagaId':sid,'steps':steps})
 return doc
def main():
 a=argparse.ArgumentParser(); a.add_argument('--root',required=True,type=Path); s=a.add_subparsers(dest='cmd',required=True)
 p=s.add_parser('begin'); p.add_argument('component'); p.add_argument('operation'); p.add_argument('change'); p.add_argument('key'); p.add_argument('--rollback',default='checkpoint'); p.add_argument('--correlation-json',default='{}')
 p=s.add_parser('gate'); p.add_argument('tx'); p.add_argument('name'); p.add_argument('status'); p.add_argument('--evidence'); p.add_argument('--detail',default='')
 p=s.add_parser('transition'); p.add_argument('tx'); p.add_argument('target'); p.add_argument('--reason',required=True); p.add_argument('--expected-version',type=int)
 p=s.add_parser('lease'); p.add_argument('tx'); p.add_argument('--seconds',type=int,default=60); p.add_argument('--receipt')
 p=s.add_parser('heartbeat'); p.add_argument('tx'); p.add_argument('lease_id'); p.add_argument('--seconds',type=int,default=60)
 p=s.add_parser('checkpoint'); p.add_argument('tx'); p.add_argument('name'); p.add_argument('paths',nargs='+'); p.add_argument('--expected-version',type=int)
 s.add_parser('reconcile'); s.add_parser('verify')
 p=s.add_parser('saga-create'); p.add_argument('saga_id'); p.add_argument('--steps-json',required=True)
 x=a.parse_args(); root=rootok(x.root)
 try:
  if x.cmd=='begin': z=begin(root,x.component,x.operation,x.change,x.key,x.rollback,json.loads(x.correlation_json))
  elif x.cmd=='gate': z=gate(root,x.tx,x.name,x.status,x.evidence,x.detail)
  elif x.cmd=='transition': z=transition(root,x.tx,x.target,x.reason,x.expected_version)
  elif x.cmd=='lease': z=lease(root,x.tx,x.seconds,x.receipt)
  elif x.cmd=='heartbeat': z=heartbeat(root,x.tx,x.lease_id,x.seconds)
  elif x.cmd=='checkpoint': z=checkpoint(root,x.tx,x.name,x.paths,x.expected_version)
  elif x.cmd=='reconcile': z=reconcile(root)
  elif x.cmd=='verify': z=verify(root)
  else: z=saga(root,x.saga_id,json.loads(x.steps_json))
  print(json.dumps(z,indent=2,sort_keys=True))
 except X as e:
  print(json.dumps({'status':'ERROR','error':type(e).__name__,'message':str(e)}),file=sys.stderr); raise SystemExit(e.code)
if __name__=='__main__': main()
