#!/usr/bin/env python3
from __future__ import annotations
import argparse, concurrent.futures, datetime as dt, hashlib, hmac, http.client, json, os, re, socket, sqlite3, subprocess, sys, tempfile, time, uuid
from pathlib import Path
from urllib.parse import urlsplit
import jsonschema

VERSION="1.3.0"; ID=re.compile(r"^[A-Za-z0-9][A-Za-z0-9._:-]{0,127}$")
class E(Exception): code=8
class Validation(E): code=6
class Denied(E): code=30
class CheckError(E): code=31
def utc(): return dt.datetime.now(dt.timezone.utc).isoformat(timespec="milliseconds").replace("+00:00","Z")
def canon(x): return (json.dumps(x,sort_keys=True,separators=(",",":"))+"\n").encode()
def load(p):
    if p.is_symlink() or not p.is_file(): raise Validation(f"unsafe or missing file: {p}")
    try:return json.loads(p.read_text())
    except Exception as e: raise Validation(f"invalid JSON {p}: {e}")
def schema(root,rel,doc):
    try:jsonschema.Draft202012Validator(load(root/rel),format_checker=jsonschema.FormatChecker()).validate(doc)
    except jsonschema.ValidationError as e: raise Validation(f"schema failure: {e.message}")
def policy(root):
    d=load(root/"config/validation_v3/policy-v1.3.0.json"); schema(root,"schemas/validation_v3/policy.schema.json",d); return d
def valid(v,n,nullable=False):
    if nullable and v is None:return None
    if not isinstance(v,str) or not ID.fullmatch(v): raise Validation(f"invalid {n}")
    return v
def secret(ref):
    pre="secret://env/"
    if not ref.startswith(pre):raise Validation("unsupported secret provider")
    v=os.getenv(ref[len(pre):])
    if not v:raise Validation("required HMAC key unavailable")
    return v.encode()
def db(root):
    p=root/"health_v3/state/validation.db";p.parent.mkdir(parents=True,exist_ok=True)
    c=sqlite3.connect(p,timeout=30,isolation_level=None);c.execute("PRAGMA journal_mode=WAL");c.execute("PRAGMA synchronous=FULL");c.execute("PRAGMA busy_timeout=30000")
    c.executescript("""CREATE TABLE IF NOT EXISTS receipts(receipt_id TEXT PRIMARY KEY,run_id TEXT,component TEXT,phase TEXT,check_id TEXT,status TEXT,severity TEXT,failure_class TEXT,receipt_json TEXT,receipt_hash TEXT,created_at TEXT,transaction_id TEXT);
CREATE TABLE IF NOT EXISTS runs(run_id TEXT PRIMARY KEY,component TEXT,phase TEXT,status TEXT,started_at TEXT,finished_at TEXT,required_count INTEGER,pass_count INTEGER,warn_count INTEGER,fail_count INTEGER,error_count INTEGER,transaction_id TEXT,change_id TEXT);
CREATE TABLE IF NOT EXISTS health(component TEXT PRIMARY KEY,status TEXT,failures INTEGER,successes INTEGER,last_check_at TEXT,last_success_at TEXT,last_change_at TEXT,last_receipt_id TEXT);
CREATE TABLE IF NOT EXISTS denials(denial_id TEXT PRIMARY KEY,at_utc TEXT,reason TEXT,request_hash TEXT,receipt_json TEXT);""")
    return c
def atomic(p,data):
    p.parent.mkdir(parents=True,exist_ok=True);fd,tmp=tempfile.mkstemp(prefix=f".{p.name}.",dir=p.parent)
    try:
      os.fchmod(fd,0o640)
      with os.fdopen(fd,"wb") as f:f.write(data);f.flush();os.fsync(f.fileno())
      os.replace(tmp,p)
    finally:
      if os.path.exists(tmp):os.unlink(tmp)
def redact(v):
    keypat=re.compile(r"(?i)(password|secret|token|authorization|cookie|api[_-]?key|private[_-]?key|credential)")
    jwt=re.compile(r"\beyJ[\w-]{8,}\.[\w-]{8,}\.[\w-]{8,}\b")
    if isinstance(v,dict):return {k:("[REDACTED]" if keypat.search(k) else redact(x)) for k,x in v.items()}
    if isinstance(v,list):return [redact(x) for x in v]
    if isinstance(v,str):
      v=re.sub(r"(?i)\b(Bearer|Basic)\s+\S+",r"\1 [REDACTED]",v);return jwt.sub("[REDACTED_JWT]",v)
    return v
def audit(root,pol,event,payload):
    cmd=root/pol["auditCommand"]
    if not cmd.exists():
      if pol["auditRequired"]:raise CheckError("audit logger unavailable")
      return None
    body={"message":event,"component":"validation","operation":event,"fields":redact(payload)}
    r=subprocess.run([str(cmd),"emit","AUDIT"],input=json.dumps(body),text=True,capture_output=True,timeout=10)
    if r.returncode and pol["auditRequired"]:raise CheckError("audit emission failed")
    try:return json.loads(r.stdout).get("eventId")
    except Exception:return None
def tx_validate(root,pol,component,phase,ctx):
    tid=ctx.get("transactionId")
    if phase in {"pre_commit","post_commit","evidence_seal"} and not tid:raise Denied("transaction required for phase")
    if not tid:return None
    valid(tid,"transactionId");cmd=root/pol["stateCommand"]
    r=subprocess.run([str(cmd),"tx-get",tid],capture_output=True,text=True,timeout=10)
    if r.returncode:raise Denied("transaction unavailable")
    d=json.loads(r.stdout)
    if d.get("component")!=component or d.get("changeId")!=ctx.get("changeId"):raise Denied("transaction component/change mismatch")
    allowed={"pre_commit":{"VALIDATING","PREPARED"},"post_commit":{"COMMITTING","VALIDATING"},"evidence_seal":{"VALIDATING","COMMITTING"}}.get(phase)
    if allowed and d.get("state") not in allowed:raise Denied("transaction state not valid for phase")
    return d
def exec_check(root,pol,contract,ctx):
    cmd=root/pol["executionCommand"]; req={"schemaVersion":"2.0","command":contract["execution"]["command"],"args":contract["execution"].get("args",[]),
       "operation":f'validate-{contract["checkId"]}',"component":contract["component"],"idempotencyKey":f'{ctx["runId"]}-{contract["checkId"]}',
       "correlation":{"run_id":ctx["runId"],"change_id":ctx.get("changeId"),"operator_id":ctx.get("operatorId","validator")}}
    r=subprocess.run([str(cmd),"run"],input=json.dumps(req),text=True,capture_output=True,timeout=300)
    try:receipt=json.loads(r.stdout)
    except Exception:receipt={}
    return {"status":"PASS" if r.returncode==0 else "FAIL","executionReceiptId":receipt.get("executionId") or receipt.get("receiptId"),"executionReceiptHash":receipt.get("receiptHash"),"exitCode":r.returncode,"detail":redact(receipt)}
class NoRedirect(http.client.HTTPConnection):pass
def http_check(pol,criteria):
    u=urlsplit(criteria["url"])
    if u.scheme!="http" or u.hostname!="127.0.0.1" or u.port not in pol["http"]["allowedLoopbackPorts"]:raise Denied("HTTP destination not approved")
    c=http.client.HTTPConnection("127.0.0.1",u.port,timeout=10)
    c.request("GET",u.path or "/",headers={"Host":"127.0.0.1","User-Agent":"TCDS-EIF-Validator/1.3"})
    r=c.getresponse();body=r.read(pol["http"]["maxBodyBytes"]+1);ctype=(r.getheader("Content-Type") or "").split(";")[0]
    if 300<=r.status<400:raise Denied("redirects forbidden")
    if ctype and ctype not in pol["http"]["allowedContentTypes"]:raise CheckError("content type rejected")
    text=body[:pol["http"]["maxBodyBytes"]].decode(errors="replace")
    ok=r.status in criteria.get("statusCodes",[200]) and (not criteria.get("bodyRegex") or re.search(criteria["bodyRegex"],text,re.I))
    return {"status":"PASS" if ok else "FAIL","statusCode":r.status,"body":text,"truncated":len(body)>pol["http"]["maxBodyBytes"]}
def composite(root,contract,ctx):
    probe=contract["criteria"].get("probe")
    evidence_file=root/"health_v3/state/probes"/f"{probe}.json"
    if not evidence_file.exists():return {"status":"ERROR","error":"server-specific probe result unavailable"}
    d=load(evidence_file);return {"status":"PASS" if d.get("status")=="PASS" else "FAIL","probe":d}
def evidence_check(root,pol,ctx):
    sid=valid(ctx.get("sessionId"),"sessionId");rid=valid(ctx.get("runId"),"runId");pid=valid(ctx.get("profileId"),"profileId")
    path=root/pol["evidence"]["sqlitePath"]
    if not path.is_file():return {"status":"ERROR","error":"authoritative evidence database unavailable"}
    c=sqlite3.connect(path); rows=c.execute("SELECT source_type,valid,correlation_confidence,event_time_utc,session_id,run_id,profile_id,event_hash_verified,schema_valid FROM evidence_records WHERE session_id=? AND run_id=? AND profile_id=?",(sid,rid,pid)).fetchall()
    required=set(pol["evidence"]["requiredSources"]);valid_sources=set();conf=[];late=[];invalid=[]
    now=dt.datetime.now(dt.timezone.utc)
    for source,v,cc,t,s,r,p,hv,sv in rows:
      age=(now-dt.datetime.fromisoformat(t.replace("Z","+00:00"))).total_seconds()
      if s!=sid or r!=rid or p!=pid:invalid.append(source);continue
      if not(v and hv and sv):invalid.append(source);continue
      if age>pol["evidence"]["maximumEvidenceAgeSeconds"]:late.append(source);continue
      valid_sources.add(source);conf.append(float(cc))
    missing=sorted(required-valid_sources);pct=len(required&valid_sources)/len(required)*100;minc=min(conf) if conf else 0
    ok=pct>=pol["evidence"]["minimumCompleteness"] and minc>=pol["evidence"]["minimumCorrelationConfidence"] and not missing and not invalid
    return {"status":"PASS" if ok else "FAIL","requiredSources":sorted(required),"validSources":sorted(valid_sources),"missingSources":missing,"lateSources":late,"invalidSources":invalid,"completenessPercentage":pct,"minimumCorrelationConfidenceObserved":minc}
def sign(pol,receipt):
    unsigned={**receipt,"authentication":{}};return hmac.new(secret(pol["receiptHmacSecretReference"]),canon(unsigned),hashlib.sha256).hexdigest()
def persist_receipt(root,pol,receipt):
    receipt["authentication"]={"type":"HMAC-SHA256","keyReference":pol["receiptHmacSecretReference"],"value":sign(pol,receipt)}
    schema(root,"schemas/validation_v3/receipt.schema.json",receipt)
    c=db(root);data=json.dumps(receipt,sort_keys=True,separators=(",",":"));rh=hashlib.sha256(data.encode()).hexdigest()
    c.execute("BEGIN IMMEDIATE")
    try:
      c.execute("INSERT INTO receipts VALUES(?,?,?,?,?,?,?,?,?,?,?,?)",(receipt["receiptId"],receipt["runId"],receipt["component"],receipt["phase"],receipt["checkId"],receipt["status"],receipt["severity"],receipt["failureClass"],data,rh,receipt["finishedAtUtc"],receipt["linkage"].get("transactionId")))
      c.execute("COMMIT")
    except Exception:c.execute("ROLLBACK");raise
    path=root/"health_v3/reports"/receipt["component"]/receipt["phase"]/f'{hashlib.sha256(receipt["receiptId"].encode()).hexdigest()}.json'
    atomic(path,json.dumps(receipt,indent=2).encode()+b"\n");return rh
def run_one(root,pol,contract,ctx):
    start=time.monotonic();sa=utc();status="ERROR";obs={};link={"transactionId":ctx.get("transactionId"),"changeId":ctx.get("changeId"),"executionReceiptId":None,"executionReceiptHash":None,"auditEventId":None,"evidenceManifestId":ctx.get("evidenceManifestId"),"sessionId":ctx.get("sessionId"),"profileId":ctx.get("profileId"),"cohortId":ctx.get("cohortId")}
    try:
      if contract["mode"]=="exec":
        result=exec_check(root,pol,contract,ctx);link["executionReceiptId"]=result.pop("executionReceiptId",None);link["executionReceiptHash"]=result.pop("executionReceiptHash",None)
      elif contract["mode"]=="http":result=http_check(pol,contract["criteria"])
      elif contract["mode"]=="evidence":result=evidence_check(root,pol,ctx)
      else:result=composite(root,contract,ctx)
      status=result.pop("status");obs=result
    except Denied as e:status="DENIED";obs={"error":str(e)}
    except CheckError as e:status="ERROR";obs={"error":str(e)}
    except Exception as e:status="ERROR";obs={"error":type(e).__name__+":"+str(e)}
    severity="INFO" if status=="PASS" else contract["severityOnFailure"]
    receipt={"schemaVersion":"3.0","receiptId":str(uuid.uuid4()),"runId":ctx["runId"],"component":contract["component"],"phase":ctx["phase"],"checkId":contract["checkId"],"status":status,"severity":severity,"failureClass":contract["failureClass"],"startedAtUtc":sa,"finishedAtUtc":utc(),"durationMs":int((time.monotonic()-start)*1000),"observations":redact(obs),"linkage":link,"authentication":{}}
    link["auditEventId"]=audit(root,pol,"VALIDATION_CHECK_COMPLETED",{"receiptId":receipt["receiptId"],"status":status,"checkId":contract["checkId"]})
    rh=persist_receipt(root,pol,receipt);return receipt,rh
def denial(root,pol,reason,request):
    did=str(uuid.uuid4());data={"denialId":did,"atUtc":utc(),"reason":reason,"request":redact(request)}
    key=secret(pol["receiptHmacSecretReference"]);data["hmac"]=hmac.new(key,canon(data),hashlib.sha256).hexdigest()
    c=db(root);c.execute("INSERT INTO denials VALUES(?,?,?,?,?)",(did,data["atUtc"],reason,hashlib.sha256(canon(request)).hexdigest(),json.dumps(data)));return data
def run(root,args):
    pol=policy(root);component=valid(args.component,"component");phase=valid(args.phase,"phase")
    if phase not in pol["phases"]:raise Validation("unknown phase")
    comp=pol["components"].get(component)
    if not comp or phase not in comp["phases"]:raise Denied("phase not approved for component")
    ctx=json.loads(args.context_json);ctx["runId"]=valid(ctx.get("runId") or str(uuid.uuid4()),"runId");ctx["phase"]=phase
    for k in ["transactionId","changeId","sessionId","profileId","cohortId","evidenceManifestId","operatorId"]:
      if ctx.get(k) is not None:valid(ctx[k],k)
    tx_validate(root,pol,component,phase,ctx)
    required=comp["phases"][phase]
    if args.checks:
      for cid in args.checks:
        valid(cid,"checkId")
        if cid not in required:raise Denied("caller cannot replace or cross-bind mandatory checks")
      if set(args.checks)!=set(required):raise Denied("mandatory check set cannot be reduced")
    contracts=[]
    for cid in required:
      cp=root/"validators_v3/contracts"/f"{cid}.json";d=load(cp);schema(root,"schemas/validation_v3/contract.schema.json",d)
      if d["component"]!=component or phase not in d["phases"]:raise Denied("contract ownership or phase mismatch")
      contracts.append(d)
    started=utc();receipts=[]
    with concurrent.futures.ThreadPoolExecutor(max_workers=pol["maxParallelChecks"]) as ex:
      for rec,rh in [f.result() for f in [ex.submit(run_one,root,pol,c,ctx) for c in contracts]]:receipts.append((rec,rh))
    counts={s:sum(1 for r,_ in receipts if r["status"]==s) for s in ["PASS","WARN","FAIL","ERROR","DENIED","SKIP"]}
    status="PASS" if counts["PASS"]==len(required) else "FAIL"
    c=db(root);c.execute("INSERT INTO runs VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?)",(ctx["runId"],component,phase,status,started,utc(),len(required),counts["PASS"],counts["WARN"],counts["FAIL"]+counts["DENIED"],counts["ERROR"],ctx.get("transactionId"),ctx.get("changeId")))
    update_health(root,pol,component,status,receipts[-1][0]["receiptId"] if receipts else None)
    run_doc={"runId":ctx["runId"],"component":component,"phase":phase,"status":status,"counts":counts,"receipts":[{"receiptId":r["receiptId"],"receiptHash":h} for r,h in receipts]}
    atomic(root/"health_v3/reports"/component/phase/f'run-{hashlib.sha256(ctx["runId"].encode()).hexdigest()}.json',json.dumps(run_doc,indent=2).encode()+b"\n")
    if ctx.get("transactionId"):
      # Side-effect-free linkage through state engine gate command if supported.
      sc=root/pol["stateCommand"]
      subprocess.run([str(sc),"gate-record",ctx["transactionId"],f"validation:{phase}","PASS" if status=="PASS" else "FAIL","--receipt-json",json.dumps(run_doc)],capture_output=True,text=True,timeout=10)
    metrics(root);return run_doc
def update_health(root,pol,component,result,receipt):
    c=db(root);c.execute("BEGIN IMMEDIATE")
    try:
      row=c.execute("SELECT status,failures,successes,last_success_at,last_change_at FROM health WHERE component=?",(component,)).fetchone()
      cur,fail,succ,lasts,lastc=row if row else ("UNKNOWN",0,0,None,utc())
      if result=="PASS":succ+=1;fail=0
      else:fail+=1;succ=0
      if result=="PASS" and succ>=pol["health"]["recoveryThreshold"]:new="HEALTHY"
      elif result!="PASS" and fail>=pol["health"]["failureThreshold"]:new="UNHEALTHY"
      elif result!="PASS":new="DEGRADED"
      else:new=cur
      now=utc();lasts=now if result=="PASS" else lasts;lastc=now if new!=cur else lastc
      c.execute("INSERT OR REPLACE INTO health VALUES(?,?,?,?,?,?,?,?)",(component,new,fail,succ,now,lasts,lastc,receipt));c.execute("COMMIT")
    except Exception:c.execute("ROLLBACK");raise
def status(root):
    pol=policy(root);c=db(root);now=dt.datetime.now(dt.timezone.utc);out=[]
    maint={}
    mf=root/pol["health"]["maintenanceFile"]
    if mf.exists():
      try:maint=load(mf)
      except Exception:maint={}
    for row in c.execute("SELECT component,status,failures,successes,last_check_at,last_success_at,last_change_at,last_receipt_id FROM health ORDER BY component"):
      comp,state,fail,succ,last,lasts,changed,receipt=row
      effective="MAINTENANCE" if comp in maint.get("components",[]) else ("STALE" if last and (now-dt.datetime.fromisoformat(last.replace("Z","+00:00"))).total_seconds()>pol["health"]["staleAfterSeconds"] else state)
      out.append({"component":comp,"status":effective,"storedStatus":state,"consecutiveFailures":fail,"consecutiveSuccesses":succ,"lastCheckAtUtc":last,"lastSuccessAtUtc":lasts,"lastChangeAtUtc":changed,"lastReceiptId":receipt})
    return {"components":out}
def metrics(root):
    s=status(root);lines=["# HELP tcds_validation_component_health Component health state","# TYPE tcds_validation_component_health gauge"]
    states=["HEALTHY","DEGRADED","UNHEALTHY","STALE","MAINTENANCE","UNKNOWN"]
    for c in s["components"]:
      for st in states:lines.append(f'tcds_validation_component_health{{component="{c["component"]}",state="{st}"}} {1 if c["status"]==st else 0}')
      lines.append(f'tcds_validation_consecutive_failures{{component="{c["component"]}"}} {c["consecutiveFailures"]}')
    p=root/"health_v3/metrics/validation.prom";atomic(p,("\n".join(lines)+"\n").encode())
def main():
    a=argparse.ArgumentParser();a.add_argument("--root",required=True,type=Path);s=a.add_subparsers(dest="cmd",required=True)
    p=s.add_parser("run");p.add_argument("component");p.add_argument("--phase",required=True);p.add_argument("--checks",nargs="*");p.add_argument("--context-json",default="{}")
    s.add_parser("status");s.add_parser("metrics")
    x=a.parse_args()
    try:
      pol=policy(x.root)
      out=run(x.root,x) if x.cmd=="run" else status(x.root) if x.cmd=="status" else (metrics(x.root) or {"status":"PASS"})
      print(json.dumps(out,indent=2,sort_keys=True))
    except E as e:
      try:denial(x.root,policy(x.root),str(e),vars(x))
      except Exception:pass
      print(json.dumps({"status":"ERROR","error":type(e).__name__,"message":str(e)}),file=sys.stderr);raise SystemExit(e.code)
if __name__=="__main__":main()
