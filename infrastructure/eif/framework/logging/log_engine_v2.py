#!/usr/bin/env python3
from __future__ import annotations
import argparse,datetime as dt,fcntl,hashlib,hmac,json,os,re,socket,stat,subprocess,sys,tempfile,uuid
from pathlib import Path
LEVELS={'TRACE':10,'DEBUG':20,'INFO':30,'NOTICE':35,'WARN':40,'ERROR':50,'FATAL':60,'SUCCESS':70,'AUDIT':80}
SAFE=re.compile(r'^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$');SENS=re.compile(r'(?i)(password|passwd|pwd|secret|token|api[_-]?key|authorization|cookie|private[_-]?key|client[_-]?secret|credential)')
AUTH=re.compile(r'(?i)\b(Bearer|Basic)\s+[A-Za-z0-9._~+/=-]+');JWT=re.compile(r'\beyJ[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}\b');URI=re.compile(r'(?i)([a-z][a-z0-9+.-]*://)([^/@:\s]+):([^/@\s]+)@');CTL=re.compile(r'[\x00-\x08\x0b\x0c\x0e-\x1f\x7f]')
class X(Exception):code=8
class Integrity(X):code=15
class Unsafe(X):code=17
class Policy(X):code=18
class Capacity(X):code=19
def utc():return dt.datetime.now(dt.timezone.utc).isoformat(timespec='milliseconds').replace('+00:00','Z')
def canon(x):return (json.dumps(x,sort_keys=True,separators=(',',':'),ensure_ascii=False)+'\n').encode()
def sha(b):return hashlib.sha256(b).hexdigest()
def depth(v,n=0):
 if isinstance(v,dict):return max([n]+[depth(x,n+1) for x in v.values()])
 if isinstance(v,list):return max([n]+[depth(x,n+1) for x in v])
 return n
def clean(s):
 s=CTL.sub('',str(s).replace('\r','\\r').replace('\n','\\n'));s=AUTH.sub(lambda m:m.group(1)+' [REDACTED]',s);s=JWT.sub('[REDACTED_JWT]',s);return URI.sub(lambda m:m.group(1)+'[REDACTED]:[REDACTED]@',s)
def redact(v,k=''):
 if SENS.search(k):return '[REDACTED]'
 if isinstance(v,dict):return {str(a):redact(b,str(a)) for a,b in v.items()}
 if isinstance(v,list):return [redact(x,k) for x in v]
 return clean(v) if isinstance(v,str) else v
def rootok(root):
 if not root.is_absolute() or root.is_symlink():raise Unsafe('unsafe root')
 r=root.resolve(strict=True);cur=Path(r.anchor)
 for part in r.parts[1:]:cur/=part; (cur.is_symlink()) and (_ for _ in ()).throw(Unsafe(f'symlink component {cur}'))
 return r
def child(root,*parts,mkdir=False):
 r=rootok(root)
 if any(x in ('','..','.') or '/' in x or chr(92) in x for x in parts):raise Unsafe('unsafe path component')
 p=r.joinpath(*parts);p.parent.mkdir(parents=True,exist_ok=True,mode=0o750);cur=r
 for x in p.relative_to(r).parts[:-1]:
  cur/=x
  if cur.is_symlink() or (cur.exists() and not cur.is_dir()):raise Unsafe(f'unsafe path {cur}')
 q=p.parent.resolve(strict=True)
 if q!=r and r not in q.parents:raise Unsafe('path escape')
 if p.is_symlink():raise Unsafe('symlink refused')
 if mkdir:p.mkdir(exist_ok=True,mode=0o750)
 return p
def atomic(p,data):
 fd,tmp=tempfile.mkstemp(prefix='.'+p.name+'.',dir=p.parent)
 try:
  os.fchmod(fd,0o640)
  with os.fdopen(fd,'wb') as f:f.write(data);f.flush();os.fsync(f.fileno())
  os.replace(tmp,p)
 finally:
  if os.path.exists(tmp):os.unlink(tmp)
def cfg(root):
 p=child(root,'runtime','resolved-config.json')
 if not p.exists():p=child(root,'config','defaults','framework.json')
 return json.loads(p.read_text())
def get(d,key,default=None):
 for k in key.split('.'):
  if not isinstance(d,dict) or k not in d:return default
  d=d[k]
 return d
def setup(root):
 for x in [('logs','audit','active'),('logs','audit','sealed'),('logs','integrity'),('state','locks')]:child(root,*x,mkdir=True)
def state(root,stream):
 if not SAFE.fullmatch(stream):raise Unsafe('invalid stream')
 p=child(root,'logs','integrity',stream+'.active.json')
 if p.exists():return json.loads(p.read_text()),p
 sid=str(uuid.uuid4());return {'stream':stream,'segmentId':sid,'segmentNumber':1,'filename':dt.datetime.now(dt.timezone.utc).strftime('%Y-%m-%dT%H%M%SZ')+'--segment-000001--'+sid+'.jsonl','nextSequence':1,'previousEventHash':'0'*64,'previousSegmentHash':'0'*64,'events':0,'bytes':0,'createdAtUtc':utc()},p
def verifyfile(p):
 prev='0'*64;first=0;last=0;n=0
 for i,line in enumerate(p.open(),1):
  e=json.loads(line);h=e.pop('eventHash',None)
  if h!=sha(canon(e)) or e.get('previousHash')!=prev:raise Integrity(f'bad chain {p.name}:{i}')
  if not first:first=e['sequence']
  last=e['sequence'];prev=h;n=i
 return {'firstSequence':first,'lastSequence':last,'eventCount':n,'lastEventHash':prev,'fileSha256':sha(p.read_bytes()),'sizeBytes':p.stat().st_size}
def seal(root,stream,keyref=None):
 st,sp=state(root,stream);p=child(root,'logs','audit','active',st['filename'])
 if not p.exists() or not p.stat().st_size:return {'status':'EMPTY'}
 v=verifyfile(p);m={'schemaVersion':'1.0','stream':stream,'segmentId':st['segmentId'],'segmentNumber':st['segmentNumber'],'filename':p.name,'sealedAtUtc':utc(),'previousSegmentHash':st['previousSegmentHash'],**v};m['segmentHash']=sha(canon(m))
 if keyref:
  if not keyref.startswith('secret://env/'):raise Policy('unsupported HMAC reference')
  env=keyref.rsplit('/',1)[-1];key=os.getenv(env)
  if not key:raise Policy('missing HMAC key')
  m['authentication']={'type':'HMAC-SHA256','keyReference':keyref,'value':hmac.new(key.encode(),canon(m),hashlib.sha256).hexdigest()}
 else:m['authentication']={'type':'HASH_CHAIN_ONLY'}
 atomic(child(root,'logs','integrity',p.name+'.manifest.json'),canon(m));os.replace(p,child(root,'logs','audit','sealed',p.name));num=st['segmentNumber']+1;sid=str(uuid.uuid4());st.update({'segmentId':sid,'segmentNumber':num,'filename':dt.datetime.now(dt.timezone.utc).strftime('%Y-%m-%dT%H%M%SZ')+f'--segment-{num:06d}--'+sid+'.jsonl','nextSequence':st['nextSequence'],'previousEventHash':'0'*64,'previousSegmentHash':m['segmentHash'],'events':0,'bytes':0,'createdAtUtc':utc()});atomic(sp,canon(st));return m
def emit(root,a,payload):
 c=cfg(root);lc=get(c,'logging',{}) or {};minl=str(lc.get('level','INFO')).upper()
 if LEVELS[a.level]<LEVELS.get(minl,30):return {'status':'FILTERED'}
 payload=redact(payload) if get(lc,'redaction.enabled',True) else payload
 if len(canon(payload))>int(lc.get('maxEventBytes',a.max_event_bytes)) or depth(payload)>int(lc.get('maxJsonDepth',a.max_depth)):raise Capacity('event policy limit')
 setup(root);lp=child(root,'state','locks','audit-'+a.stream+'.lock');fd=os.open(lp,os.O_CREAT|os.O_RDWR|os.O_NOFOLLOW,0o640)
 try:
  fcntl.flock(fd,fcntl.LOCK_EX);st,sp=state(root,a.stream);p=child(root,'logs','audit','active',st['filename'])
  if p.exists() and (p.stat().st_size>=int(get(c,'logging.audit.segmentMaxBytes',104857600)) or st['events']>=int(get(c,'logging.audit.segmentMaxEvents',100000))):seal(root,a.stream,get(c,'logging.integrity.hmacSecretReference'));st,sp=state(root,a.stream);p=child(root,'logs','audit','active',st['filename'])
  now=utc();seq=st['nextSequence'];e={'schemaVersion':'1.0','eventId':str(uuid.uuid4()),'timestampUtc':now,'level':a.level,'message':clean(payload.pop('message','')),'host':socket.gethostname(),'pid':os.getpid(),'frameworkVersion':'0.5.0','component':clean(payload.pop('component','framework')),'operation':clean(payload.pop('operation','unspecified')),'runId':os.getenv('EIF_RUN_ID','unknown'),'correlationId':os.getenv('EIF_CORRELATION_ID','unknown'),'deploymentId':os.getenv('EIF_DEPLOYMENT_ID','unknown'),'traceparent':clean(payload.pop('traceparent','')),'sequence':seq,'segmentId':st['segmentId'],'previousHash':st['previousEventHash'],'fields':payload};e['eventHash']=sha(canon(e));line=canon(e);o=os.open(p,os.O_APPEND|os.O_CREAT|os.O_WRONLY|os.O_NOFOLLOW,0o640)
  try:os.write(o,line);os.fsync(o)
  finally:os.close(o)
  st.update({'nextSequence':seq+1,'previousEventHash':e['eventHash'],'events':st['events']+1,'bytes':st['bytes']+len(line),'updatedAtUtc':now});atomic(sp,canon(st))
 finally:fcntl.flock(fd,fcntl.LOCK_UN);os.close(fd)
 if lc.get('console',True):print(f'{now} {a.level:<7} [{e["component"]}] {e["message"]}',file=sys.stderr if LEVELS[a.level]>=40 else sys.stdout)
 pol=get(c,'logging.journald.policy','disabled')
 if pol!='disabled':
  msg=json.dumps({'MESSAGE':e['message'],'PRIORITY':3 if LEVELS[a.level]>=50 else 6,'SYSLOG_IDENTIFIER':'tcds-eif','TCDS_EVENT_ID':e['eventId'],'TCDS_COMPONENT':e['component'],'TCDS_OPERATION':e['operation'],'TCDS_RUN_ID':e['runId'],'TCDS_CORRELATION_ID':e['correlationId'],'TCDS_DEPLOYMENT_ID':e['deploymentId'],'TCDS_EVENT_HASH':e['eventHash']});r=subprocess.run(['systemd-cat','--identifier=tcds-eif'],input=msg,text=True,capture_output=True)
  if r.returncode and pol=='required':raise Policy('journald failed')
 return e
def verify(root,stream):
 if not SAFE.fullmatch(stream):raise Unsafe('invalid stream')
 prev='0'*64;n=0
 for p in sorted(child(root,'logs','audit','sealed').glob('*--segment-*--*.jsonl')):
  mp=child(root,'logs','integrity',p.name+'.manifest.json');m=json.loads(mp.read_text());v=verifyfile(p)
  if m['previousSegmentHash']!=prev or m['fileSha256']!=v['fileSha256'] or m['lastEventHash']!=v['lastEventHash']:raise Integrity('segment mismatch')
  x=dict(m);x.pop('authentication',None);seg=x.pop('segmentHash')
  if sha(canon(x))!=seg:raise Integrity('manifest hash mismatch')
  prev=seg;n+=1
 return {'status':'PASS','sealedSegments':n,'lastSegmentHash':prev}
def main():
 ap=argparse.ArgumentParser();ap.add_argument('--root',required=True,type=Path);s=ap.add_subparsers(dest='cmd',required=True);p=s.add_parser('emit');p.add_argument('--level',choices=LEVELS,required=True);p.add_argument('--stream',default='framework');p.add_argument('--max-event-bytes',type=int,default=262144);p.add_argument('--max-depth',type=int,default=12);p=s.add_parser('seal');p.add_argument('--stream',default='framework');p.add_argument('--hmac-ref');p=s.add_parser('verify');p.add_argument('--stream',default='framework');a=ap.parse_args();r=rootok(a.root)
 try:
  if a.cmd=='emit':
   raw=sys.stdin.buffer.read(a.max_event_bytes+1)
   if len(raw)>a.max_event_bytes:raise Capacity('too large')
   result=emit(r,a,json.loads(raw or b'{}'))
  elif a.cmd=='seal':result=seal(r,a.stream,a.hmac_ref)
  else:result=verify(r,a.stream)
  print(json.dumps(result,indent=2,sort_keys=True))
 except X as e:print(json.dumps({'status':'ERROR','error':type(e).__name__,'message':str(e)}),file=sys.stderr);raise SystemExit(e.code)
if __name__=='__main__':main()
