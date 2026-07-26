#!/usr/bin/env python3
from __future__ import annotations
import argparse,datetime as dt,hashlib,hmac,json,os,platform,re,shutil,socket,subprocess,sys,tempfile,time,uuid
from pathlib import Path
import jsonschema
VERSION='1.5.0'
class E(Exception): code=8
class V(E): code=6
class F(E): code=32
class I(E): code=33
def utc(): return dt.datetime.now(dt.timezone.utc).isoformat(timespec='milliseconds').replace('+00:00','Z')
def canon(x): return (json.dumps(x,sort_keys=True,separators=(',',':'))+'\n').encode()
def load(p):
 if p.is_symlink() or not p.is_file(): raise V(f'unsafe or missing JSON: {p}')
 return json.loads(p.read_text())
def validate(root,rel,doc): jsonschema.Draft202012Validator(load(root/rel)).validate(doc)
def policy(root):
 d=load(root/'config/certification_v2/policy-v1.5.0.json');validate(root,'schemas/certification_v2/policy.schema.json',d);return d
def secret(ref):
 name=ref.split('/')[-1];v=os.getenv(name)
 if not v: raise I(f'required secret missing: {name}')
 return v.encode()
def atomic(p,b):
 p.parent.mkdir(parents=True,exist_ok=True);fd,tmp=tempfile.mkstemp(prefix='.'+p.name+'.',dir=p.parent)
 with os.fdopen(fd,'wb') as f:f.write(b);f.flush();os.fsync(f.fileno())
 os.replace(tmp,p)
def redact(s,n):
 s=s[-n:];s=re.sub(r'(?i)(password|secret|token|authorization|cookie|api[_-]?key)\s*[:=]\s*\S+',r'\1=[REDACTED]',s);s=re.sub(r'\b(?:\d{1,3}\.){3}\d{1,3}\b','[REDACTED_IP]',s);return s
def suites(root): return {'security_negative':[root/'tests/security/test-negative.sh'],'framework_concurrency':[root/'tests/framework_concurrency/test-all.sh'],'failure_injection':[root/'tests/failure_injection_v2/test-all.sh'],'recovery':[root/'tests/recovery_v2/test-all.sh'],'cross_milestone_integration':[root/'tests/integration_v2/test-all.sh'],'production_acceptance':[root/'tests/production_acceptance_v2/test-all.sh'],'framework_core':[root/'tests/unit/test-core.sh'],'configuration':[root/'tests/unit/test-config-engine.sh'],'structured_logging':[root/'tests/logging/test-integrity.sh'],'execution':[root/'tests/execution/test-green-tier1.sh'],'state_transaction':[root/'tests/state_v2/test-all.sh'],'backup_restore':[root/'tests/backup_v2/test-all.sh'],'validation_health':[root/'tests/validation_v3/test-all.sh']}
def lineage(root,p):
 cli={'1B.1':'eif-info','1B.2':'eif-config','1B.3':'eif-log-v2','1B.4':'eif-exec-v2','1B.5':'eif-state-v2','1B.6':'eif-backup-v2','1B.7':'eif-validate-v3'};r={k:{'required':v,'status':'PASS' if (root/'bin'/cli[k]).exists() else 'FAIL'} for k,v in p['requiredMilestones'].items()};return {'milestones':r,'status':'PASS' if all(x['status']=='PASS' for x in r.values()) else 'FAIL'}
def run_script(p,t,e,m):
 st=time.monotonic()
 try:r=subprocess.run([str(p)],capture_output=True,text=True,timeout=t,env=e)
 except subprocess.TimeoutExpired:return {'name':p.name,'status':'FAIL','exitCode':124,'stderr':'timeout','stdout':'','durationMs':t*1000}
 return {'name':p.name,'status':'PASS' if r.returncode==0 else 'FAIL','exitCode':r.returncode,'stderr':redact(r.stderr,m),'stdout':redact(r.stdout,m),'durationMs':int((time.monotonic()-st)*1000)}
def acceptance(root,p,mode):
 checks={'lineage':lineage(root,p),'systemd':{'status':'PASS' if Path('/run/systemd/system').exists() else 'FAIL'},'serviceAccount':{'status':'PASS' if subprocess.run(['id','tcds-validator'],capture_output=True).returncode==0 else 'FAIL'},'confinement':{'status':'PASS' if (Path('/sys/module/apparmor').exists() or Path('/sys/fs/selinux').exists()) else 'FAIL'},'remoteEvidence':{'status':'PASS' if list(root.glob(p['acceptance']['remoteExportReceiptGlob'])) else 'FAIL'}}
 return {'status':'PASS' if all(x['status']=='PASS' for x in checks.values()) else 'FAIL','checks':checks}
def run(root,a):
 p=policy(root);mode=a.mode or p['mode'];partial=bool(a.suites);selected=a.suites or p['requiredSuites'];env=dict(os.environ)
 if mode=='UNIT_TEST':
  env.setdefault('EIF_CERTIFICATION_HMAC_KEY','unit');env.setdefault('EIF_VALIDATION_HMAC_KEY','unit');env.setdefault('EIF_BACKUP_HMAC_KEY','unit');env.setdefault('EIF_APPROVAL_HMAC_KEY','unit')
 else:
  for k in ['EIF_CERTIFICATION_HMAC_KEY','EIF_VALIDATION_HMAC_KEY','EIF_BACKUP_HMAC_KEY','EIF_APPROVAL_HMAC_KEY']:
   if not os.getenv(k): raise I(k)
 sr=[];find=[]
 for s in selected:
  tests=[run_script(x,a.timeout,env,p['reporting']['maxCapturedOutputBytes']) for x in suites(root).get(s,[]) if x.exists()]
  status='PASS' if tests and all(x['status']=='PASS' for x in tests) else 'FAIL';sr.append({'suite':s,'status':status,'tests':tests})
  for x in tests:
   if x['status']!='PASS':find.append({'severity':'CRITICAL' if s in ['recovery','production_acceptance'] else 'HIGH','class':'TEST_ERROR','suite':s,'test':x['name'],'message':x['stderr']})
 pa=acceptance(root,p,mode) if mode=='PRODUCTION_CERTIFICATION' else {'status':'INCOMPLETE','checks':{}}
 pct=sum(1 for x in sr if x['status']=='PASS')/len(sr)*100 if sr else 0;thr={'passPercentage':pct,'allPassed':pct>=p['thresholds']['requiredPassPercentage'] and not find}
 full=set(selected)==set(p['requiredSuites'])
 if mode=='PRODUCTION_CERTIFICATION' and full and not partial and all(x['status']=='PASS' for x in sr) and pa['status']=='PASS' and thr['allPassed'] and lineage(root,p)['status']=='PASS':status,grade='PASS','GREEN_TIER_1'
 elif any(x['status']=='FAIL' for x in sr):status,grade='FAIL','RED'
 else:status,grade='INCOMPLETE','AMBER'
 rid=str(uuid.uuid4());rep={'schemaVersion':'2.0','reportId':rid,'frameworkVersion':VERSION,'mode':mode,'hostIdentity':{'hostname':socket.gethostname(),'bootId':Path('/proc/sys/kernel/random/boot_id').read_text().strip() if Path('/proc/sys/kernel/random/boot_id').exists() else 'unknown','kernel':platform.release(),'architecture':platform.machine()},'startedAtUtc':utc(),'finishedAtUtc':utc(),'durationMs':0,'status':status,'grade':grade,'certifyingRun':bool(full and not partial),'lineage':lineage(root,p),'thresholdEvaluation':thr,'suiteResults':sr,'findings':find,'productionAcceptance':pa,'linkage':{'remoteExportReceipt':None},'authentication':{}}
 key=secret(p['authentication']['reportHmacSecretReference']);rep['authentication']={'type':'HMAC-SHA256','keyReference':p['authentication']['reportHmacSecretReference'],'value':hmac.new(key,canon({**rep,'authentication':{}}),hashlib.sha256).hexdigest()};validate(root,'schemas/certification_v2/report.schema.json',rep);out=root/'certification_v2/reports'/f'{rid}.json';atomic(out,json.dumps(rep,indent=2).encode()+b'\n');atomic(root/'certification_v2/reports/latest.json',json.dumps(rep,indent=2).encode()+b'\n')
 if grade=='RED': raise F(str(out))
 return rep
def verify(root,a):
 p=policy(root);d=load(Path(a.report));exp=hmac.new(secret(p['authentication']['reportHmacSecretReference']),canon({**d,'authentication':{}}),hashlib.sha256).hexdigest();
 if not hmac.compare_digest(exp,d['authentication']['value']):raise V('HMAC mismatch')
 return {'status':'PASS','reportId':d['reportId'],'grade':d['grade']}
def main():
 a=argparse.ArgumentParser();a.add_argument('--root',required=True,type=Path);s=a.add_subparsers(dest='cmd',required=True);r=s.add_parser('run');r.add_argument('--mode',choices=['UNIT_TEST','STAGING_CERTIFICATION','PRODUCTION_CERTIFICATION']);r.add_argument('--suites',nargs='*');r.add_argument('--timeout',type=int,default=120);v=s.add_parser('verify');v.add_argument('report');x=a.parse_args()
 try:o=run(x.root,x) if x.cmd=='run' else verify(x.root,x);print(json.dumps(o,indent=2,sort_keys=True))
 except E as e:print(json.dumps({'status':'ERROR','error':type(e).__name__,'message':str(e)}),file=sys.stderr);raise SystemExit(e.code)
if __name__=='__main__':main()
