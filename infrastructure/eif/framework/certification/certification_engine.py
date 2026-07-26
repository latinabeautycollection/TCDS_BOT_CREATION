#!/usr/bin/env python3
from __future__ import annotations
import argparse, datetime as dt, hashlib, hmac, json, os, shutil, socket, subprocess, sys, tempfile, time, uuid
from pathlib import Path
import jsonschema

VERSION="1.4.0"
class CError(Exception): code=8
class Validation(CError): code=6
class CertificationFailed(CError): code=32

def utc():
    return dt.datetime.now(dt.timezone.utc).isoformat(timespec="milliseconds").replace("+00:00","Z")
def canon(x):
    return (json.dumps(x,sort_keys=True,separators=(",",":"))+"\n").encode()
def load(p):
    if p.is_symlink() or not p.is_file(): raise Validation(f"unsafe or missing JSON: {p}")
    try:return json.loads(p.read_text())
    except Exception as e: raise Validation(f"invalid JSON {p}: {e}")
def validate(root,rel,doc):
    try:jsonschema.Draft202012Validator(load(root/rel),format_checker=jsonschema.FormatChecker()).validate(doc)
    except jsonschema.ValidationError as e: raise Validation(f"schema validation failed: {e.message}")
def policy(root):
    d=load(root/"config/certification/policy-v1.4.0.json")
    validate(root,"schemas/certification/policy.schema.json",d)
    return d
def secret(ref):
    p="secret://env/"
    if not ref.startswith(p): raise Validation("unsupported secret provider")
    v=os.getenv(ref[len(p):])
    if not v: raise Validation("required certification HMAC key unavailable")
    return v.encode()
def atomic(path,data):
    path.parent.mkdir(parents=True,exist_ok=True,mode=0o750)
    fd,tmp=tempfile.mkstemp(prefix=f".{path.name}.",dir=path.parent)
    try:
        os.fchmod(fd,0o640)
        with os.fdopen(fd,"wb") as f:
            f.write(data);f.flush();os.fsync(f.fileno())
        os.replace(tmp,path)
    finally:
        if os.path.exists(tmp):os.unlink(tmp)
def run_script(path,timeout=120,env=None):
    started=time.monotonic()
    r=subprocess.run([str(path)],capture_output=True,text=True,timeout=timeout,env=env)
    return {
        "name":path.name,"path":str(path),"status":"PASS" if r.returncode==0 else "FAIL",
        "exitCode":r.returncode,"durationMs":int((time.monotonic()-started)*1000),
        "stdout":r.stdout[-65536:],"stderr":r.stderr[-65536:]
    }
def suite_map(root):
    return {
      "framework_core":[root/"tests/unit/test-core.sh",root/"tests/smoke/test-load.sh"],
      "configuration":[root/"tests/unit/test-config-engine.sh",root/"tests/unit/test-secret-references.sh"],
      "structured_logging":[root/"tests/logging/test-redaction.sh",root/"tests/logging/test-integrity.sh",root/"tests/logging/test-concurrency.sh"],
      "execution":[root/"tests/execution/test-green-tier1.sh"],
      "state_transaction":[root/"tests/state_v2/test-all.sh"],
      "backup_restore":[root/"tests/backup_v2/test-all.sh",root/"tests/backup_v2/test-negative.sh"],
      "validation_health":[root/"tests/validation_v3/test-all.sh"],
      "security_negative":[root/"tests/security/test-negative.sh"],
      "concurrency":[root/"tests/concurrency/test-concurrency.sh"],
      "failure_injection":[root/"tests/failure_injection/test-failure-injection.sh"],
      "recovery":[root/"tests/recovery/test-recovery.sh"],
      "integration":[root/"tests/integration/test-integration.sh"],
      "production_acceptance":[root/"tests/acceptance/test-production-acceptance.sh"]
    }
def acceptance(root,pol):
    checks={}
    checks["envoy_binary"]=Path("/usr/bin/envoy").is_file()
    checks["suricata_binary"]=Path("/usr/bin/suricata").is_file()
    checks["pqp_validator"]=(root/"bin/eif-validate-v3").is_file()
    checks["postgresql_client"]=shutil.which("psql") is not None
    checks["redis_client"]=shutil.which("redis-cli") is not None
    checks["clock_tool"]=shutil.which("timedatectl") is not None
    checks["validation_hmac"]=bool(os.getenv("EIF_VALIDATION_HMAC_KEY"))
    checks["backup_hmac"]=bool(os.getenv("EIF_BACKUP_HMAC_KEY"))
    checks["certification_hmac"]=bool(os.getenv("EIF_CERTIFICATION_HMAC_KEY"))
    checks["validator_user"]=subprocess.run(["id","tcds-validator"],capture_output=True).returncode==0
    checks["apparmor_or_equivalent"]=Path("/sys/module/apparmor").exists() or Path("/sys/fs/selinux").exists()
    checks["remote_immutable_configured"]=bool(os.getenv("EIF_REMOTE_EVIDENCE_CONFIGURED"))
    required={
      "envoy_binary":pol["productionAcceptance"]["requireEnvoy"],
      "suricata_binary":pol["productionAcceptance"]["requireSuricata"],
      "pqp_validator":pol["productionAcceptance"]["requirePqp"],
      "postgresql_client":pol["productionAcceptance"]["requirePostgresql"],
      "redis_client":pol["productionAcceptance"]["requireRedis"],
      "clock_tool":pol["productionAcceptance"]["requireClockSync"],
      "remote_immutable_configured":pol["productionAcceptance"]["requireRemoteImmutableEvidence"],
      "validator_user":pol["productionAcceptance"]["requireDedicatedServiceAccounts"],
      "apparmor_or_equivalent":pol["productionAcceptance"]["requireAppArmorOrEquivalent"]
    }
    missing=[k for k,v in required.items() if v and not checks.get(k)]
    if pol["productionAcceptance"]["requireHmacKeys"]:
        for k in ("validation_hmac","backup_hmac","certification_hmac"):
            if not checks[k]:missing.append(k)
    return {"checks":checks,"missing":sorted(set(missing)),"status":"PASS" if not missing else "INCOMPLETE"}
def run(root,args):
    pol=policy(root);start=time.monotonic();started=utc();report_id=str(uuid.uuid4())
    env={**os.environ,"EIF_ROOT":str(root),"EIF_ENVIRONMENT":"test"}
    env.setdefault("EIF_VALIDATION_HMAC_KEY","test-validation-key")
    env.setdefault("EIF_BACKUP_HMAC_KEY","test-backup-key")
    env.setdefault("EIF_APPROVAL_HMAC_KEY","test-approval-key")
    suites=suite_map(root);suite_results=[];findings=[];evidence=[]
    selected=args.suites or pol["suites"]
    for suite in selected:
        scripts=suites.get(suite,[])
        results=[]
        if not scripts:
            results.append({"name":suite,"status":"FAIL","exitCode":127,"durationMs":0,"stdout":"","stderr":"suite not registered"})
        for script in scripts:
            if not script.is_file():
                results.append({"name":script.name,"path":str(script),"status":"FAIL","exitCode":127,"durationMs":0,"stdout":"","stderr":"test missing"})
            else:
                try:results.append(run_script(script,args.timeout,env))
                except subprocess.TimeoutExpired:
                    results.append({"name":script.name,"path":str(script),"status":"FAIL","exitCode":124,"durationMs":args.timeout*1000,"stdout":"","stderr":"timeout"})
        status="PASS" if results and all(r["status"]=="PASS" for r in results) else "FAIL"
        suite_results.append({"suite":suite,"status":status,"tests":results})
        for r in results:
            evidence.append({"suite":suite,"test":r["name"],"status":r["status"],"exitCode":r["exitCode"],"durationMs":r["durationMs"]})
            if r["status"]!="PASS":
                findings.append({"severity":"CRITICAL","suite":suite,"test":r["name"],"message":r["stderr"][-2048:] or "test failed"})
    pa=acceptance(root,pol)
    failed=sum(1 for s in suite_results if s["status"]!="PASS")
    passed=len(suite_results)-failed
    critical=sum(1 for f in findings if f["severity"]=="CRITICAL")
    all_suites_pass=failed==0
    production_complete=pa["status"]=="PASS"
    if all_suites_pass and production_complete:
        status="PASS";grade="GREEN_TIER_1"
    elif all_suites_pass:
        status="INCOMPLETE";grade="AMBER"
    else:
        status="FAIL";grade="RED"
    summary={"suiteCount":len(suite_results),"passedSuites":passed,"failedSuites":failed,
             "criticalFindings":critical,"productionAcceptanceComplete":production_complete}
    report={"schemaVersion":"1.0","reportId":report_id,"frameworkVersion":VERSION,"host":socket.gethostname(),
            "startedAtUtc":started,"finishedAtUtc":utc(),"durationMs":int((time.monotonic()-start)*1000),
            "status":status,"grade":grade,"summary":summary,"suiteResults":suite_results,
            "findings":findings,"evidence":evidence,"productionAcceptance":pa,"authentication":{}}
    key=secret(pol["reportHmacSecretReference"])
    report["authentication"]={"type":"HMAC-SHA256","keyReference":pol["reportHmacSecretReference"],
      "value":hmac.new(key,canon({**report,"authentication":{}}),hashlib.sha256).hexdigest()}
    validate(root,"schemas/certification/report.schema.json",report)
    out=root/"certification/reports"/f"{report_id}.json"
    atomic(out,json.dumps(report,indent=2).encode()+b"\n")
    latest=root/"certification/reports/latest.json"
    atomic(latest,json.dumps(report,indent=2).encode()+b"\n")
    if status=="FAIL":raise CertificationFailed(json.dumps({"report":str(out),"grade":grade}))
    return report
def verify(root,args):
    pol=policy(root);d=load(Path(args.report))
    validate(root,"schemas/certification/report.schema.json",d)
    expected=hmac.new(secret(pol["reportHmacSecretReference"]),canon({**d,"authentication":{}}),hashlib.sha256).hexdigest()
    if not hmac.compare_digest(expected,d["authentication"]["value"]):raise Validation("report HMAC mismatch")
    return {"status":"PASS","reportId":d["reportId"],"grade":d["grade"]}
def main():
    a=argparse.ArgumentParser();a.add_argument("--root",required=True,type=Path);s=a.add_subparsers(dest="cmd",required=True)
    p=s.add_parser("run");p.add_argument("--suites",nargs="*");p.add_argument("--timeout",type=int,default=120)
    p=s.add_parser("verify");p.add_argument("report")
    x=a.parse_args()
    try:
        out=run(x.root,x) if x.cmd=="run" else verify(x.root,x)
        print(json.dumps(out,indent=2,sort_keys=True))
    except CError as e:
        print(json.dumps({"status":"ERROR","error":type(e).__name__,"message":str(e)}),file=sys.stderr)
        raise SystemExit(e.code)
if __name__=="__main__":main()
