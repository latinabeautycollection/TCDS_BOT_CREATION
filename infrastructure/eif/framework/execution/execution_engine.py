#!/usr/bin/env python3
from __future__ import annotations
import argparse, ctypes, datetime as dt, fcntl, hashlib, json, os, re, resource, selectors, signal, stat, subprocess, sys, tempfile, time, uuid
from pathlib import Path
from typing import Any

VERSION='0.6.0'
class E(Exception): code=8
class Denied(E): code=17
class Timeout(E): code=18
class Collision(E): code=7
class Invalid(E): code=6
class Idempotency(E): code=19

def utc(): return dt.datetime.now(dt.timezone.utc).isoformat(timespec='milliseconds').replace('+00:00','Z')
def canon(x): return (json.dumps(x,sort_keys=True,separators=(',',':'))+'\n').encode()
def sha(x): return hashlib.sha256(x).hexdigest()
def safe_root(p:Path):
 p=p.resolve();
 if not p.is_absolute() or p.is_symlink(): raise Invalid('unsafe root')
 return p

def beneath(root:Path,p:Path):
 q=p.resolve();
 try:q.relative_to(root.resolve())
 except ValueError:raise Invalid(f'path escapes root: {p}')
 for part in [q,*q.parents]:
  if part==root.parent:break
  if part.exists() and part.is_symlink():raise Invalid(f'symlink path refused: {part}')
 return q

def atomic(path:Path,data:bytes,mode=0o640,overwrite=False):
 path.parent.mkdir(parents=True,exist_ok=True,mode=0o750)
 if path.is_symlink():raise Invalid('symlink destination')
 if path.exists() and not overwrite:
  if path.read_bytes()==data:return
  raise Invalid(f'immutable collision: {path}')
 fd,tmp=tempfile.mkstemp(prefix='.'+path.name+'.',dir=path.parent)
 try:
  os.fchmod(fd,mode)
  with os.fdopen(fd,'wb') as f:f.write(data);f.flush();os.fsync(f.fileno())
  os.replace(tmp,path)
 finally:
  if os.path.exists(tmp):os.unlink(tmp)

def locked(path:Path,nonblock=True):
 path.parent.mkdir(parents=True,exist_ok=True,mode=0o750); fd=os.open(path,os.O_CREAT|os.O_RDWR|os.O_NOFOLLOW,0o640)
 try:fcntl.flock(fd,fcntl.LOCK_EX|(fcntl.LOCK_NB if nonblock else 0))
 except BlockingIOError:os.close(fd);raise Collision(f'lock busy: {path}')
 return fd

def redact(s:str):
 s=re.sub(r'(?i)(Bearer|Basic)\\s+[A-Za-z0-9._~+/=-]+',r'\\1 [REDACTED]',s)
 s=re.sub(r'(?i)(password|secret|token|api[_-]?key)=([^&\\s]+)',r'\\1=[REDACTED]',s)
 return s.replace('\\x00','')

def load(root:Path):
 p=root/'config/upgrade/execution-v0.6.0.json'; return json.loads(p.read_text())

def validate_request(req,pol):
 raw=canon(req)
 if len(raw)>pol['maxRequestBytes']:raise Invalid('request too large')
 if req.get('schemaVersion')!='1.0':raise Invalid('schemaVersion required')
 name=req.get('command','')
 if not re.fullmatch(r'[a-z][a-z0-9-]{0,63}',name):raise Invalid('invalid command name')
 if name not in pol['commands']:raise Denied('command not allowlisted')
 args=req.get('args',[])
 if not isinstance(args,list) or len(args)>pol['maxArgCount'] or not all(isinstance(x,str) for x in args):raise Invalid('invalid args')
 if any(len(x)>pol['maxArgLength'] or '\\x00' in x or '\\n' in x or '\\r' in x for x in args):raise Invalid('unsafe argument')
 cmd=pol['commands'][name]; pats=cmd.get('allowedArgPatterns',[])
 if pats:
  for a in args:
   if not any(re.fullmatch(p,a) for p in pats):raise Denied(f'argument denied: {a[:64]}')
 elif args:raise Denied('arguments not permitted')
 exe=Path(cmd['executable'])
 if not exe.is_absolute() or exe.name in pol['forbiddenExecutables']:raise Denied('forbidden executable')
 st=exe.stat()
 if not stat.S_ISREG(st.st_mode) or st.st_mode & stat.S_ISUID or st.st_mode & stat.S_ISGID:raise Denied('unsafe executable')
 if not os.access(exe,os.X_OK):raise Denied('executable not executable')
 attempts=int(req.get('attempts',1)); timeout=int(req.get('timeoutSeconds',pol['defaultTimeoutSeconds']))
 if attempts>1 and (not cmd.get('retryable') or not cmd.get('idempotent')):raise Denied('retries require retryable idempotent command')
 if attempts<1 or attempts>pol['maximumAttempts'] or timeout<1 or timeout>pol['maximumTimeoutSeconds']:raise Invalid('invalid attempts/timeout')
 if cmd.get('requiredEuid') is not None and os.geteuid()!=cmd['requiredEuid']:raise Denied('privilege boundary violation')
 return cmd,args,attempts,timeout,raw

def child_setup(pol):
 os.setsid(); os.umask(0o077)
 lim=pol['resourceLimits']
 resource.setrlimit(resource.RLIMIT_CPU,(lim['cpuSeconds'],lim['cpuSeconds']))
 resource.setrlimit(resource.RLIMIT_AS,(lim['addressSpaceBytes'],lim['addressSpaceBytes']))
 resource.setrlimit(resource.RLIMIT_FSIZE,(lim['fileSizeBytes'],lim['fileSizeBytes']))
 resource.setrlimit(resource.RLIMIT_NOFILE,(lim['openFiles'],lim['openFiles']))
 if hasattr(resource,'RLIMIT_NPROC'):resource.setrlimit(resource.RLIMIT_NPROC,(lim['processes'],lim['processes']))
 try: ctypes.CDLL(None).prctl(38,1,0,0,0) # PR_SET_NO_NEW_PRIVS
 except Exception: pass

def execute(root:Path,req):
 pol=load(root); cmd,args,attempts,timeout,raw=validate_request(req,pol)
 component=req.get('component','framework'); operation=req['operation']; request_hash=sha(raw)
 idem=req.get('idempotencyKey'); idem_path=root/'state/idempotency'/f'{idem}.json' if idem else None
 comp_lock=locked(root/'state/locks'/f'execution-{component}.lock')
 try:
  if idem_path and idem_path.exists():
   old=json.loads(idem_path.read_text())
   if old['requestHash']!=request_hash:raise Idempotency('same key different request')
   receipt=root/old['receipt']; return json.loads(receipt.read_text())
  execution_id=str(uuid.uuid4()); started=utc(); receipt_rel=f'state/executions/{execution_id}.json'; receipt=root/receipt_rel
  if req.get('dryRun',False):
   result={'schemaVersion':'1.0','executionId':execution_id,'status':'DRY_RUN','command':req['command'],'args':args,'operation':operation,'component':component,'startedAtUtc':started,'finishedAtUtc':utc(),'requestHash':request_hash,'attempts':0,'exitCode':None,'timedOut':False,'stdout':'','stderr':''}
   atomic(receipt,canon(result));
   if idem_path:atomic(idem_path,canon({'requestHash':request_hash,'receipt':receipt_rel}))
   return result
  env={}
  if not pol['cleanEnvironment']:env.update(os.environ)
  for k in pol['allowedEnvironment']:
   if k in os.environ:env[k]=os.environ[k]
  for k,v in req.get('environment',{}).items():
   if k not in pol['allowedEnvironment']:raise Denied(f'environment variable denied: {k}')
   env[k]=v
  cwd=root
  if req.get('cwd'):cwd=beneath(root,root/req['cwd'].lstrip('/'))
  limit=pol['defaultOutputLimitBytes']; final=None
  for attempt in range(1,attempts+1):
   t0=time.monotonic(); proc=subprocess.Popen([cmd['executable'],*args],stdin=subprocess.PIPE,stdout=subprocess.PIPE,stderr=subprocess.PIPE,cwd=cwd,env=env,preexec_fn=lambda:child_setup(pol),text=False)
   try:
    out,err=proc.communicate(req.get('stdin','').encode(),timeout=timeout); timed=False
   except subprocess.TimeoutExpired:
    timed=True
    try:os.killpg(proc.pid,signal.SIGTERM)
    except ProcessLookupError:pass
    try:out,err=proc.communicate(timeout=pol['terminationGraceSeconds'])
    except subprocess.TimeoutExpired:
     try:os.killpg(proc.pid,signal.SIGKILL)
     except ProcessLookupError:pass
     out,err=proc.communicate()
   truncated_out=len(out)>limit; truncated_err=len(err)>limit
   out=out[:limit];err=err[:limit]
   code=proc.returncode
   ok=(not timed and code in cmd['allowedExitCodes'])
   final={'schemaVersion':'1.0','executionId':execution_id,'status':'SUCCESS' if ok else ('TIMEOUT' if timed else 'FAILED'),'command':req['command'],'args':args,'operation':operation,'component':component,'startedAtUtc':started,'finishedAtUtc':utc(),'durationMs':round((time.monotonic()-t0)*1000,3),'requestHash':request_hash,'attempts':attempt,'exitCode':code,'timedOut':timed,'stdout':redact(out.decode(errors='replace')),'stderr':redact(err.decode(errors='replace')),'stdoutTruncated':truncated_out,'stderrTruncated':truncated_err}
   if ok:break
   if attempt<attempts:time.sleep(min(2**(attempt-1),8))
  atomic(receipt,canon(final))
  if idem_path:atomic(idem_path,canon({'requestHash':request_hash,'receipt':receipt_rel}))
  return final
 finally:
  fcntl.flock(comp_lock,fcntl.LOCK_UN);os.close(comp_lock)

def main():
 ap=argparse.ArgumentParser();ap.add_argument('--root',required=True,type=Path);ap.add_argument('command',choices=['run','validate']);a=ap.parse_args()
 try:
  root=safe_root(a.root); raw=sys.stdin.buffer.read(load(root)['maxRequestBytes']+1)
  if len(raw)>load(root)['maxRequestBytes']:raise Invalid('request too large')
  req=json.loads(raw)
  result=execute(root,req) if a.command=='run' else {'status':'VALID','command':validate_request(req,load(root))[0]}
  print(json.dumps(result,indent=2,sort_keys=True));sys.exit(0 if result.get('status') in ('SUCCESS','DRY_RUN','VALID') else 1)
 except E as e:print(json.dumps({'status':'ERROR','error':type(e).__name__,'message':str(e)}),file=sys.stderr);sys.exit(e.code)
 except Exception as e:print(json.dumps({'status':'ERROR','error':'Unexpected','message':str(e)}),file=sys.stderr);sys.exit(8)
if __name__=='__main__':main()
