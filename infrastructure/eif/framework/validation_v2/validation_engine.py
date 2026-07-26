#!/usr/bin/env python3
from __future__ import annotations
import argparse, concurrent.futures, datetime as dt, hashlib, hmac, json, os, re, sqlite3, subprocess, sys, tempfile, time, urllib.request, uuid
from pathlib import Path
import jsonschema

VERSION="1.2.0"
class VError(Exception): code=8
class Validation(VError): code=6
class CheckFailed(VError): code=28
class EvidenceIncomplete(VError): code=29
def utc(): return dt.datetime.now(dt.timezone.utc).isoformat(timespec="milliseconds").replace("+00:00","Z")
def canon(x): return (json.dumps(x,sort_keys=True,separators=(",",":"))+"\n").encode()
def load(p):
    if p.is_symlink() or not p.is_file(): raise Validation(f"unsafe or missing JSON: {p}")
    try:return json.loads(p.read_text())
    except Exception as e: raise Validation(f"invalid JSON {p}: {e}")
def validate(root,schema_rel,doc):
    schema=load(root/schema_rel)
    try:jsonschema.Draft202012Validator(schema,format_checker=jsonschema.FormatChecker()).validate(doc)
    except jsonschema.ValidationError as e: raise Validation(f"schema validation failed: {e.message}")
def policy(root):
    d=load(root/"config/validation/policy-v1.2.0.json"); validate(root,"schemas/validation/policy.schema.json",d); return d
def secret(ref):
    p="secret://env/"
    if not ref.startswith(p): raise Validation("unsupported secret provider")
    v=os.getenv(ref[len(p):])
    if not v: raise Validation("required validation HMAC key unavailable")
    return v.encode()
def redact(v):
    pat=re.compile(r"(?i)(password|secret|token|authorization|cookie|api[_-]?key)")
    if isinstance(v,dict):return {k:("[REDACTED]" if pat.search(k) else redact(x)) for k,x in v.items()}
    if isinstance(v,list):return [redact(x) for x in v]
    if isinstance(v,str):return re.sub(r"(?i)\b(Bearer|Basic)\s+\S+",r"\1 [REDACTED]",v)
    return v
def db(root):
    p=root/"health/state/validation.db"; p.parent.mkdir(parents=True,exist_ok=True)
    c=sqlite3.connect(p,timeout=30)
    c.execute("PRAGMA busy_timeout=30000")
    c.execute("PRAGMA synchronous=FULL")
    c.executescript("""
    CREATE TABLE IF NOT EXISTS receipts(receipt_id TEXT PRIMARY KEY,component TEXT,check_id TEXT,status TEXT,severity TEXT,
      failure_class TEXT,started_at TEXT,finished_at TEXT,receipt_path TEXT,receipt_hash TEXT,run_id TEXT,transaction_id TEXT);
    CREATE TABLE IF NOT EXISTS health_state(component TEXT PRIMARY KEY,current_status TEXT,consecutive_failures INTEGER,
      consecutive_successes INTEGER,last_check_at TEXT,last_change_at TEXT,last_receipt_id TEXT);
    CREATE TABLE IF NOT EXISTS validation_runs(run_id TEXT PRIMARY KEY,component TEXT,status TEXT,started_at TEXT,finished_at TEXT,
      required_count INTEGER,pass_count INTEGER,warn_count INTEGER,fail_count INTEGER,transaction_id TEXT);
    """)
    return c
def render(s,ctx):
    out=s
    for k,v in ctx.items():out=out.replace("${"+k+"}",str(v))
    if "${" in out: raise Validation(f"unresolved template variable: {out}")
    return out
def bounded(text,maxb):
    b=text.encode(errors="replace")
    return b[:maxb].decode(errors="replace"),len(b)>maxb
def run_contract(root,pol,contract,ctx,evidence):
    started=time.monotonic(); started_at=utc(); obs={}
    status="PASS"; severity="INFO"; failure_class=contract["failureClass"]
    try:
        mode=contract["mode"]; criteria=contract["successCriteria"]
        if mode=="command":
            command=contract["command"]
            if not command or not Path(command).is_file(): raise CheckFailed("trusted command unavailable")
            args=[render(x,ctx) for x in contract["arguments"]]
            r=subprocess.run([command,*args],capture_output=True,text=True,timeout=contract["timeoutSeconds"],
                             env={"PATH":"/usr/sbin:/usr/bin:/sbin:/bin","LANG":"C","LC_ALL":"C"})
            so,tr1=bounded(r.stdout,pol["maxOutputBytes"]); se,tr2=bounded(r.stderr,pol["maxOutputBytes"])
            obs={"exitCode":r.returncode,"stdout":so,"stderr":se,"outputTruncated":tr1 or tr2}
            if r.returncode not in criteria.get("exitCodes",[0]): raise CheckFailed("exit code rejected")
            if criteria.get("stdoutRegex") and not re.search(criteria["stdoutRegex"],r.stdout.strip()): raise CheckFailed("stdout criteria failed")
        elif mode=="http":
            url=render(criteria["url"],ctx)
            req=urllib.request.Request(url,headers={"User-Agent":"TCDS-EIF-Validator/1.2.0"})
            with urllib.request.urlopen(req,timeout=contract["timeoutSeconds"]) as resp:
                body=resp.read(pol["maxOutputBytes"]+1); code=resp.status
            body_text=body[:pol["maxOutputBytes"]].decode(errors="replace")
            obs={"url":url,"statusCode":code,"body":body_text,"outputTruncated":len(body)>pol["maxOutputBytes"]}
            if code not in criteria.get("statusCodes",[200]): raise CheckFailed("HTTP status rejected")
            if criteria.get("bodyRegex") and not re.search(criteria["bodyRegex"],body_text,re.I): raise CheckFailed("HTTP body criteria failed")
        elif mode=="file":
            p=Path(render(criteria["path"],ctx))
            count=sum(1 for _ in p.iterdir()) if p.is_dir() else (1 if p.exists() else 0)
            obs={"path":str(p),"entryCount":count}
            if count>criteria.get("maxEntries",0): raise CheckFailed("file threshold exceeded")
        elif mode=="evidence":
            ep=pol["evidenceCompleteness"]; required=set(ep["requiredSources"])
            received=set(evidence.get("receivedSources",[])); missing=sorted(required-received)
            pct=(len(required & received)/len(required)*100) if required else 100
            confidence=float(evidence.get("correlationConfidence",0))
            skew=float(evidence.get("clockSkewSeconds",999999))
            obs={"requiredSources":sorted(required),"receivedSources":sorted(received),"missingSources":missing,
                 "completenessPercentage":pct,"correlationConfidence":confidence,"clockSkewSeconds":skew}
            if pct<ep["minimumPercentage"] or confidence<ep["minimumCorrelationConfidence"] or abs(skew)>ep["clockSkewMaxSeconds"]:
                raise EvidenceIncomplete("evidence completeness policy failed")
        else:
            raise Validation(f"unsupported check mode: {mode}")
    except EvidenceIncomplete as e:
        status="FAIL"; severity=contract["severityOnFailure"]; obs["error"]=str(e)
    except Exception as e:
        status="FAIL"; severity=contract["severityOnFailure"]; obs["error"]=str(e)
    finished_at=utc(); duration=int((time.monotonic()-started)*1000)
    receipt={"schemaVersion":"1.0","receiptId":str(uuid.uuid4()),"component":contract["component"],
             "checkId":contract["checkId"],"checkVersion":contract["version"],"status":status,"severity":severity,
             "failureClass":failure_class,"startedAtUtc":started_at,"finishedAtUtc":finished_at,"durationMs":duration,
             "observations":redact(obs),"correlation":{
               "runId":ctx.get("RUN_ID"),"transactionId":ctx.get("TRANSACTION_ID"),"changeId":ctx.get("CHANGE_ID"),
               "sessionId":ctx.get("SESSION_ID"),"profileId":ctx.get("PROFILE_ID"),"cohortId":ctx.get("COHORT_ID"),
               "evidenceManifestId":ctx.get("EVIDENCE_MANIFEST_ID")
             },"authentication":{}}
    key=secret(pol["receiptHmacSecretReference"])
    receipt["authentication"]={"type":"HMAC-SHA256","keyReference":pol["receiptHmacSecretReference"],
      "value":hmac.new(key,canon({**receipt,"authentication":{}}),hashlib.sha256).hexdigest()}
    validate(root,"schemas/validation/receipt.schema.json",receipt)
    out=root/"health/reports"/receipt["component"]/receipt["checkId"]
    out.mkdir(parents=True,exist_ok=True)
    path=out/f'{receipt["receiptId"]}.json'; path.write_text(json.dumps(receipt,indent=2)+"\n")
    c=db(root); rh=hashlib.sha256(path.read_bytes()).hexdigest()
    c.execute("INSERT INTO receipts VALUES(?,?,?,?,?,?,?,?,?,?,?,?)",
      (receipt["receiptId"],receipt["component"],receipt["checkId"],status,severity,failure_class,
       started_at,finished_at,str(path.relative_to(root)),rh,ctx.get("RUN_ID"),ctx.get("TRANSACTION_ID")))
    c.commit()
    return receipt
def load_contract(root,check_id):
    p=root/"validators/contracts"/f"{check_id}.json"; d=load(p); validate(root,"schemas/validation/check-contract.schema.json",d); return d
def run_component(root,args):
    pol=policy(root)
    comp=pol["components"].get(args.component)
    if not comp: raise Validation("unknown component")
    context=json.loads(args.context_json or "{}")
    context.setdefault("EIF_ROOT",str(root))
    context.setdefault("RUN_ID",str(uuid.uuid4()))
    evidence=json.loads(args.evidence_json or "{}")
    checks=args.checks or comp["requiredChecks"]
    missing_contracts=[x for x in checks if not (root/"validators/contracts"/f"{x}.json").exists()]
    if missing_contracts and pol["failClosed"]: raise Validation("missing check contracts: "+",".join(missing_contracts))
    contracts=[load_contract(root,x) for x in checks if (root/"validators/contracts"/f"{x}.json").exists()]
    started=utc(); receipts=[]
    init=db(root); init.execute("PRAGMA journal_mode=WAL"); init.commit(); init.close()
    with concurrent.futures.ThreadPoolExecutor(max_workers=pol["maxParallelChecks"]) as ex:
        fut=[ex.submit(run_contract,root,pol,c,context,evidence) for c in contracts]
        for f in fut: receipts.append(f.result())
    counts={s:sum(1 for r in receipts if r["status"]==s) for s in ["PASS","WARN","FAIL","ERROR","SKIP"]}
    status="PASS" if counts["FAIL"]==0 and counts["ERROR"]==0 and not missing_contracts else "FAIL"
    run={"runId":context["RUN_ID"],"component":args.component,"status":status,"startedAtUtc":started,
         "finishedAtUtc":utc(),"counts":counts,"receipts":[r["receiptId"] for r in receipts],
         "missingContracts":missing_contracts}
    path=root/"health/reports"/args.component/f'run-{context["RUN_ID"]}.json'
    path.parent.mkdir(parents=True,exist_ok=True); path.write_text(json.dumps(run,indent=2)+"\n")
    c=db(root); c.execute("INSERT OR REPLACE INTO validation_runs VALUES(?,?,?,?,?,?,?,?,?,?)",
      (run["runId"],args.component,status,run["startedAtUtc"],run["finishedAtUtc"],len(checks),
       counts["PASS"],counts["WARN"],counts["FAIL"]+counts["ERROR"],context.get("TRANSACTION_ID"))); c.commit()
    update_health(root,pol,args.component,status,receipts[-1]["receiptId"] if receipts else None)
    write_metrics(root,c)
    return run
def update_health(root,pol,component,status,receipt_id):
    c=db(root); row=c.execute("SELECT current_status,consecutive_failures,consecutive_successes FROM health_state WHERE component=?",(component,)).fetchone()
    current,failures,successes=row if row else ("UNKNOWN",0,0)
    if status=="PASS": successes+=1; failures=0
    else: failures+=1; successes=0
    new=current
    th=pol["continuousHealth"]
    if status!="PASS" and failures>=th["failureThreshold"]: new="UNHEALTHY"
    elif status=="PASS" and successes>=th["recoveryThreshold"]: new="HEALTHY"
    changed=utc() if new!=current else (c.execute("SELECT last_change_at FROM health_state WHERE component=?",(component,)).fetchone() or [utc()])[0]
    c.execute("INSERT OR REPLACE INTO health_state VALUES(?,?,?,?,?,?,?)",
      (component,new,failures,successes,utc(),changed,receipt_id)); c.commit()
def write_metrics(root,c):
    rows=c.execute("SELECT component,current_status,consecutive_failures,last_check_at FROM health_state").fetchall()
    lines=["# HELP tcds_component_health Component health state (1 healthy, 0 otherwise)",
           "# TYPE tcds_component_health gauge",
           "# HELP tcds_component_consecutive_failures Consecutive failed validation runs",
           "# TYPE tcds_component_consecutive_failures gauge"]
    for component,state,failures,last in rows:
        lines.append(f'tcds_component_health{{component="{component}",state="{state}"}} {1 if state=="HEALTHY" else 0}')
        lines.append(f'tcds_component_consecutive_failures{{component="{component}"}} {failures}')
    p=root/"health/metrics/validation.prom"; p.parent.mkdir(parents=True,exist_ok=True)
    tmp=p.with_suffix(".tmp"); tmp.write_text("\n".join(lines)+"\n"); os.replace(tmp,p)
def verify_receipt(root,args):
    pol=policy(root); p=Path(args.receipt)
    if not p.is_absolute(): p=root/p
    d=load(p); validate(root,"schemas/validation/receipt.schema.json",d)
    auth=d["authentication"]; unsigned={**d,"authentication":{}}
    expected=hmac.new(secret(pol["receiptHmacSecretReference"]),canon(unsigned),hashlib.sha256).hexdigest()
    if not hmac.compare_digest(expected,auth.get("value","")): raise Validation("receipt HMAC mismatch")
    return {"status":"PASS","receiptId":d["receiptId"]}
def status(root,args):
    c=db(root); rows=c.execute("SELECT component,current_status,consecutive_failures,consecutive_successes,last_check_at,last_change_at,last_receipt_id FROM health_state ORDER BY component").fetchall()
    return {"components":[{"component":r[0],"status":r[1],"consecutiveFailures":r[2],"consecutiveSuccesses":r[3],"lastCheckAtUtc":r[4],"lastChangeAtUtc":r[5],"lastReceiptId":r[6]} for r in rows]}
def main():
    a=argparse.ArgumentParser(); a.add_argument("--root",required=True,type=Path); s=a.add_subparsers(dest="cmd",required=True)
    p=s.add_parser("run"); p.add_argument("component"); p.add_argument("--checks",nargs="*"); p.add_argument("--context-json",default="{}"); p.add_argument("--evidence-json",default="{}")
    p=s.add_parser("verify-receipt"); p.add_argument("receipt")
    s.add_parser("status")
    x=a.parse_args()
    try:
        out=run_component(x.root,x) if x.cmd=="run" else verify_receipt(x.root,x) if x.cmd=="verify-receipt" else status(x.root,x)
        print(json.dumps(out,indent=2,sort_keys=True))
    except VError as e:
        print(json.dumps({"status":"ERROR","error":type(e).__name__,"message":str(e)}),file=sys.stderr); raise SystemExit(e.code)
if __name__=="__main__":main()
