#!/usr/bin/env python3
from __future__ import annotations
import argparse, ctypes, datetime as dt, fcntl, grp, hashlib, hmac, json, os, pwd, re
import resource, selectors, signal, stat, subprocess, sys, tempfile, time, uuid
from pathlib import Path
from typing import Any

VERSION="0.7.0"
class EIFError(Exception): code=8
class Invalid(EIFError): code=6
class Collision(EIFError): code=7
class Denied(EIFError): code=17
class TimedOut(EIFError): code=18
class Idempotency(EIFError): code=19
class Integrity(EIFError): code=20
class AuditFailure(EIFError): code=21
class ReconcileRequired(EIFError): code=22

IDENT=re.compile(r"^[a-z][a-z0-9-]{0,63}$")
IDKEY=re.compile(r"^[A-Za-z0-9._:-]{1,128}$")
TRACEPARENT=re.compile(r"^00-[a-f0-9]{32}-[a-f0-9]{16}-[0-9a-f]{2}$")
SENSITIVE=re.compile(r"(?i)(password|secret|token|api[_-]?key|authorization|cookie|credential)")

def utc(): return dt.datetime.now(dt.timezone.utc).isoformat(timespec="milliseconds").replace("+00:00","Z")
def canon(x): return (json.dumps(x,sort_keys=True,separators=(",",":"),ensure_ascii=False)+"\n").encode()
def sha_bytes(x): return hashlib.sha256(x).hexdigest()
def sha_file_fd(fd):
    h=hashlib.sha256(); os.lseek(fd,0,os.SEEK_SET)
    while True:
        b=os.read(fd,1024*1024)
        if not b: break
        h.update(b)
    os.lseek(fd,0,os.SEEK_SET); return h.hexdigest()

def reject_symlink_chain(path: Path, must_exist=True):
    if not path.is_absolute(): raise Invalid("absolute path required")
    cur=Path(path.anchor)
    for part in path.parts[1:]:
        cur=cur/part
        try: st=os.lstat(cur)
        except FileNotFoundError:
            if must_exist: raise Invalid(f"missing path component: {cur}")
            continue
        if stat.S_ISLNK(st.st_mode): raise Invalid(f"symlink path refused: {cur}")
    return path

def under(root:Path,path:Path,must_exist=False):
    reject_symlink_chain(root,True)
    candidate=path if path.is_absolute() else root/path
    reject_symlink_chain(candidate,must_exist)
    norm=Path(os.path.abspath(candidate))
    try:norm.relative_to(root)
    except ValueError:raise Invalid("path escapes framework root")
    return norm

def open_nofollow(path:Path,flags:int,mode=0o640):
    reject_symlink_chain(path.parent,True)
    return os.open(path,flags|os.O_NOFOLLOW,mode)

def atomic(path:Path,data:bytes,mode=0o640,overwrite=True):
    under(path.parent,path.parent,True)
    path.parent.mkdir(parents=True,exist_ok=True,mode=0o750)
    if path.exists() and path.is_symlink(): raise Invalid("symlink destination")
    fd,tmp=tempfile.mkstemp(prefix="."+path.name+".",dir=path.parent)
    try:
        os.fchmod(fd,mode)
        with os.fdopen(fd,"wb") as f:f.write(data);f.flush();os.fsync(f.fileno())
        if not overwrite and path.exists():
            if path.read_bytes()==data:return
            raise Collision(f"immutable collision: {path}")
        os.replace(tmp,path)
        dfd=os.open(path.parent,os.O_DIRECTORY|os.O_NOFOLLOW)
        try:os.fsync(dfd)
        finally:os.close(dfd)
    finally:
        if os.path.exists(tmp):os.unlink(tmp)

def lock(path:Path,shared=False,nonblock=True):
    path.parent.mkdir(parents=True,exist_ok=True,mode=0o750)
    fd=open_nofollow(path,os.O_CREAT|os.O_RDWR,0o640)
    op=(fcntl.LOCK_SH if shared else fcntl.LOCK_EX)|(fcntl.LOCK_NB if nonblock else 0)
    try:fcntl.flock(fd,op)
    except BlockingIOError:os.close(fd);raise Collision(f"lock busy: {path}")
    return fd

def load_json(path:Path):
    reject_symlink_chain(path,True)
    with path.open(encoding="utf-8") as f:return json.load(f)

def depth(x,level=0):
    if isinstance(x,dict):return max([level]+[depth(v,level+1) for v in x.values()])
    if isinstance(x,list):return max([level]+[depth(v,level+1) for v in x])
    return level

def strict_validate(req,pol):
    allowed={"schemaVersion","command","args","operation","component","idempotencyKey",
             "attempts","timeoutSeconds","dryRun","cwd","stdin","correlation"}
    extra=set(req)-allowed
    if extra:raise Invalid(f"unknown request properties: {sorted(extra)}")
    if req.get("schemaVersion")!="2.0":raise Invalid("schemaVersion 2.0 required")
    for k in ("command","operation","component"):
        if not isinstance(req.get(k),str) or not IDENT.fullmatch(req[k]):raise Invalid(f"invalid {k}")
    args=req.get("args",[])
    if not isinstance(args,list) or len(args)>pol["maxArgCount"] or not all(isinstance(a,str) for a in args):raise Invalid("invalid args")
    for a in args:
        if len(a)>pol["maxArgLength"] or any(c in a for c in ("\x00","\n","\r")):raise Invalid("unsafe argument")
    idem=req.get("idempotencyKey")
    if idem is not None and (not isinstance(idem,str) or not IDKEY.fullmatch(idem)):raise Invalid("invalid idempotencyKey")
    if not isinstance(req.get("dryRun",False),bool):raise Invalid("invalid dryRun")
    attempts=req.get("attempts",1); timeout=req.get("timeoutSeconds",pol["defaultTimeoutSeconds"])
    if not isinstance(attempts,int) or not 1<=attempts<=pol["maximumAttempts"]:raise Invalid("invalid attempts")
    if not isinstance(timeout,int) or not 1<=timeout<=pol["maximumTimeoutSeconds"]:raise Invalid("invalid timeout")
    corr=req.get("correlation")
    if not isinstance(corr,dict):raise Invalid("correlation required")
    reqcorr={"run_id","change_id","operator_id"}
    if not reqcorr.issubset(corr):raise Invalid("missing correlation identifiers")
    allowedcorr={"session_id","run_id","profile_id","test_cohort_id","change_id","operator_id","traceparent","evidence_manifest_id"}
    if set(corr)-allowedcorr:raise Invalid("unknown correlation properties")
    for k,v in corr.items():
        if not isinstance(v,str) or (k=="traceparent" and not TRACEPARENT.fullmatch(v)) or (k!="traceparent" and not IDKEY.fullmatch(v)):
            raise Invalid(f"invalid correlation field {k}")
    sin=req.get("stdin",{"mode":"none"})
    if not isinstance(sin,dict) or set(sin)-{"mode","fd","sha256","maxBytes"}:raise Invalid("invalid stdin")
    if sin.get("mode") not in ("none","fd"):raise Invalid("invalid stdin mode")
    if sin.get("mode")=="fd":
        if not isinstance(sin.get("fd"),int) or not 3<=sin["fd"]<=9:raise Invalid("invalid stdin fd")
        if "sha256" in sin and not re.fullmatch(r"[a-f0-9]{64}",sin["sha256"]):raise Invalid("invalid stdin digest")
    if depth(req)>8:raise Invalid("request nesting too deep")
    return args,attempts,timeout,sin

def trusted_executable(root:Path,cmd):
    exe=Path(cmd["executable"])
    reject_symlink_chain(exe,True)
    fd=open_nofollow(exe,os.O_RDONLY)
    st=os.fstat(fd)
    if not stat.S_ISREG(st.st_mode):os.close(fd);raise Denied("executable not regular")
    if st.st_uid!=cmd["ownerUid"] or st.st_gid!=cmd["groupGid"]:os.close(fd);raise Denied("executable ownership mismatch")
    if stat.S_IMODE(st.st_mode)&0o022:os.close(fd);raise Denied("executable writable by group/world")
    if stat.S_IMODE(st.st_mode)>int(cmd["maxMode"],8):os.close(fd);raise Denied("executable mode exceeds policy")
    trust=load_json(root/"config/execution/trust-manifest.json")
    rec=trust.get(str(exe))
    digest=sha_file_fd(fd)
    if not rec or rec.get("sha256")!=digest or rec.get("inode")!=st.st_ino or rec.get("device")!=st.st_dev:
        os.close(fd);raise Integrity("executable trust mismatch")
    return fd,digest

def audit(root,event_type,payload,required=True):
    logger=root/"bin/eif-log-v2"
    body={"message":event_type,"component":"execution","operation":event_type.lower(),
          "event_type":event_type,"fields":payload}
    try:
        p=subprocess.run([str(logger),"emit","AUDIT"],input=canon(body),stdout=subprocess.DEVNULL,stderr=subprocess.PIPE,timeout=5)
        if p.returncode!=0:raise RuntimeError(p.stderr.decode(errors="replace")[:512])
    except Exception as e:
        if os.getenv("EIF_EXEC_AUDIT_TEST_FALLBACK")=="1":
            path=root/"state/executions/integrity/test-audit.jsonl"
            path.parent.mkdir(parents=True,exist_ok=True,mode=0o750)
            fd=open_nofollow(path,os.O_APPEND|os.O_CREAT|os.O_WRONLY,0o640)
            try:os.write(fd,canon({"timestampUtc":utc(),"type":event_type,"payload":payload}));os.fsync(fd)
            finally:os.close(fd)
            return
        if required:raise AuditFailure(f"audit unavailable: {e}")

def redact_text(s):
    s=re.sub(r"(?i)(Bearer|Basic)\s+[A-Za-z0-9._~+/=-]+",r"\1 [REDACTED]",s)
    s=re.sub(r"(?i)(password|secret|token|api[_-]?key)=([^&\s]+)",r"\1=[REDACTED]",s)
    return s.replace("\x00","")

def receipt_chain(root,receipt):
    d=root/"state/executions/integrity"; d.mkdir(parents=True,exist_ok=True,mode=0o750)
    lfd=lock(root/"state/locks/receipt-chain.lock",nonblock=False)
    try:
        statep=d/"state.json"; state=load_json(statep) if statep.exists() else {"sequence":0,"lastHash":"0"*64}
        receipt["receiptSequence"]=state["sequence"]+1
        receipt["previousReceiptHash"]=state["lastHash"]
        receipt["receiptHash"]=sha_bytes(canon(receipt))
        key=os.getenv("EIF_RECEIPT_HMAC_KEY")
        if key:receipt["receiptHmac"]=hmac.new(key.encode(),receipt["receiptHash"].encode(),hashlib.sha256).hexdigest()
        atomic(statep,canon({"sequence":receipt["receiptSequence"],"lastHash":receipt["receiptHash"],"updatedAtUtc":utc()}))
        return receipt
    finally:fcntl.flock(lfd,fcntl.LOCK_UN);os.close(lfd)

def denial(root,req,error):
    r={"schemaVersion":"2.0","executionId":str(uuid.uuid4()),"status":"DENIED","error":type(error).__name__,
       "message":str(error),"timestampUtc":utc(),"requestDigest":sha_bytes(canon(req)) if isinstance(req,dict) else None}
    try:
        r=receipt_chain(root,r)
        atomic(root/"state/executions/receipts"/f'{r["executionId"]}.json',canon(r),overwrite=False)
        audit(root,"EXECUTION_DENIED",r,required=False)
    except Exception:pass
    return r

def child_setup(pol,cmd,parent_pid):
    os.setsid();os.umask(0o077)
    libc=ctypes.CDLL(None)
    libc.prctl(38,1,0,0,0)
    libc.prctl(1,signal.SIGKILL)
    if os.getppid()!=parent_pid:os._exit(125)
    try:os.setgroups([])
    except PermissionError:
        if os.geteuid()==0:raise
    if os.geteuid()==0:
        os.setgid(cmd["runAsGid"]);os.setuid(cmd["runAsUid"])
    lim=pol["resourceLimits"]
    resource.setrlimit(resource.RLIMIT_CPU,(lim["cpuSeconds"],lim["cpuSeconds"]))
    resource.setrlimit(resource.RLIMIT_AS,(lim["addressSpaceBytes"],lim["addressSpaceBytes"]))
    resource.setrlimit(resource.RLIMIT_FSIZE,(lim["fileSizeBytes"],lim["fileSizeBytes"]))
    resource.setrlimit(resource.RLIMIT_NOFILE,(lim["openFiles"],lim["openFiles"]))
    if hasattr(resource,"RLIMIT_NPROC"):resource.setrlimit(resource.RLIMIT_NPROC,(lim["processes"],lim["processes"]))

def read_fd_payload(spec):
    if spec["mode"]=="none":return b"",None
    fd=spec["fd"]; limit=min(spec.get("maxBytes",1048576),1048576)
    chunks=[];total=0;h=hashlib.sha256()
    while True:
        b=os.read(fd,min(65536,limit-total+1))
        if not b:break
        total+=len(b)
        if total>limit:raise Invalid("protected stdin exceeds limit")
        h.update(b);chunks.append(b)
    digest=h.hexdigest()
    if spec.get("sha256") and spec["sha256"]!=digest:raise Integrity("protected stdin digest mismatch")
    return b"".join(chunks),digest

def stream_process(proc,stdin_data,timeout,grace,limit):
    if proc.stdin:
        try:proc.stdin.write(stdin_data);proc.stdin.close()
        except BrokenPipeError:pass
    sel=selectors.DefaultSelector()
    for name,pipe in (("stdout",proc.stdout),("stderr",proc.stderr)):
        os.set_blocking(pipe.fileno(),False);sel.register(pipe,selectors.EVENT_READ,name)
    out={"stdout":bytearray(),"stderr":bytearray()};trunc={"stdout":False,"stderr":False}
    deadline=time.monotonic()+timeout;timed=False
    while sel.get_map():
        remain=deadline-time.monotonic()
        if remain<=0:
            timed=True
            try:os.killpg(proc.pid,signal.SIGTERM)
            except ProcessLookupError:pass
            end=time.monotonic()+grace
            while proc.poll() is None and time.monotonic()<end:time.sleep(.05)
            if proc.poll() is None:
                try:os.killpg(proc.pid,signal.SIGKILL)
                except ProcessLookupError:pass
            remain=.2
        for key,_ in sel.select(max(0,min(remain,.2))):
            chunk=os.read(key.fileobj.fileno(),65536)
            if not chunk:sel.unregister(key.fileobj);continue
            name=key.data
            capacity=limit-len(out[name])
            if capacity>0:out[name].extend(chunk[:capacity])
            if len(chunk)>capacity:trunc[name]=True
        if proc.poll() is not None and not sel.get_map():break
    code=proc.wait()
    return bytes(out["stdout"]),bytes(out["stderr"]),trunc,code,timed

def reconcile(root):
    results=[]
    for p in (root/"state/executions/in-progress").glob("*.json"):
        j=load_json(p);pid=j.get("pid");alive=False
        if isinstance(pid,int):
            try:os.kill(pid,0);alive=True
            except OSError:pass
        j["reconciledAtUtc"]=utc();j["reconciliation"]="RUNNING_REQUIRES_OPERATOR" if alive else "ABANDONED"
        atomic(p,canon(j))
        audit(root,"EXECUTION_RECONCILED",{"executionId":j.get("executionId"),"result":j["reconciliation"]},required=False)
        results.append(j)
    return results

def execute(root,req):
    pol=load_json(root/"config/execution/policy-v2.json")
    args,attempts,timeout,sin=strict_validate(req,pol)
    name=req["command"]
    if name not in pol["commands"]:raise Denied("command not allowlisted")
    cmd=pol["commands"][name]
    if cmd.get("optional") and not Path(cmd["executable"]).exists():raise Denied("optional command unavailable")
    patterns=cmd.get("argPatterns",[])
    if cmd.get("allowedArgs")==[] and args:raise Denied("arguments not permitted")
    for a in args:
        if patterns and not any(re.fullmatch(p,a) for p in patterns):raise Denied("argument denied")
    if attempts>1 and not(cmd.get("retryable") and cmd.get("idempotent")):raise Denied("retries require idempotent retryable command")
    if cmd.get("requiredEuid") is not None and os.geteuid()!=cmd["requiredEuid"]:raise Denied("required EUID mismatch")
    if req.get("cwd"):
        cwd=under(root,root/req["cwd"].lstrip("/"),True)
    else:cwd=root
    exe_fd,exe_digest=trusted_executable(root,cmd)
    os.close(exe_fd)
    raw=canon(req);request_hash=sha_bytes(raw)
    idem=req.get("idempotencyKey");idem_digest=sha_bytes(idem.encode()) if idem else None
    idem_lock=lock(root/"state/locks"/f"idempotency-{idem_digest}.lock",nonblock=False) if idem else None
    component_digest=sha_bytes(req["component"].encode())
    comp_lock=lock(root/"state/locks"/f"execution-{component_digest}.lock",nonblock=False)
    try:
        idem_path=root/"state/idempotency"/f"{idem_digest}.json" if idem else None
        if idem_path and idem_path.exists():
            old=load_json(idem_path)
            if old["requestHash"]!=request_hash:raise Idempotency("same key different request")
            result=load_json(root/old["receipt"])
            audit(root,"IDEMPOTENT_REPLAY",{"executionId":result["executionId"],"requestHash":request_hash},pol["audit"]["required"])
            return result
        execution_id=str(uuid.uuid4());started=utc()
        base={"schemaVersion":"2.0","executionId":execution_id,"status":"IN_PROGRESS","command":name,
              "args":args,"operation":req["operation"],"component":req["component"],"correlation":req["correlation"],
              "startedAtUtc":started,"requestHash":request_hash,"executableSha256":exe_digest,
              "protectedStdinUsed":sin["mode"]=="fd"}
        journal=root/"state/executions/in-progress"/f"{execution_id}.json"
        atomic(journal,canon(base),overwrite=False)
        audit(root,"EXECUTION_REQUESTED",base,pol["audit"]["required"])
        if req.get("dryRun",False):
            result={**base,"status":"DRY_RUN","finishedAtUtc":utc(),"attemptRecords":[],"totalDurationMs":0}
        else:
            stdin_data,stdin_digest=read_fd_payload(sin)
            records=[];overall=time.monotonic();result=None
            for n in range(1,attempts+1):
                t=time.monotonic()
                env=dict(pol["immutableEnvironment"])
                env.update({"EIF_RUN_ID":req["correlation"]["run_id"],"EIF_CHANGE_ID":req["correlation"]["change_id"]})
                argv=[cmd["executable"],*cmd.get("fixedArgs",[]),*args]
                audit(root,"ATTEMPT_STARTED",{"executionId":execution_id,"attempt":n},pol["audit"]["required"])
                parent=os.getpid()
                proc=subprocess.Popen(argv,stdin=subprocess.PIPE,stdout=subprocess.PIPE,stderr=subprocess.PIPE,
                                      cwd=cwd,env=env,preexec_fn=lambda:child_setup(pol,cmd,parent),text=False)
                base["pid"]=proc.pid;base["pidStartTicks"]=Path(f"/proc/{proc.pid}/stat").read_text().split()[21] if Path(f"/proc/{proc.pid}/stat").exists() else None
                atomic(journal,canon(base))
                out,err,trunc,code,timed=stream_process(proc,stdin_data,timeout,pol["terminationGraceSeconds"],pol["defaultOutputLimitBytes"])
                ok=(not timed and code in cmd["allowedExitCodes"])
                rec={"attempt":n,"startedAtUtc":utc(),"durationMs":round((time.monotonic()-t)*1000,3),
                     "exitCode":code,"timedOut":timed,"stdout":redact_text(out.decode(errors="replace")),
                     "stderr":redact_text(err.decode(errors="replace")),"stdoutTruncated":trunc["stdout"],"stderrTruncated":trunc["stderr"]}
                records.append(rec)
                audit(root,"ATTEMPT_COMPLETED",{"executionId":execution_id,"attempt":n,"exitCode":code,"timedOut":timed},pol["audit"]["required"])
                if ok:
                    status="SUCCESS";break
                status="TIMEOUT" if timed else "FAILED"
                if n<attempts:
                    delay=min(2**(n-1),8);rec["retryDelaySeconds"]=delay;time.sleep(delay)
            result={**base,"status":status,"finishedAtUtc":utc(),"attemptRecords":records,
                    "totalDurationMs":round((time.monotonic()-overall)*1000,3),
                    "protectedStdinSha256":stdin_digest}
        result.pop("pid",None);result.pop("pidStartTicks",None)
        result=receipt_chain(root,result)
        rel=f"state/executions/receipts/{execution_id}.json"
        atomic(root/rel,canon(result),overwrite=False)
        if idem_path:atomic(idem_path,canon({"requestHash":request_hash,"receipt":rel}),overwrite=False)
        try:journal.unlink()
        except FileNotFoundError:pass
        audit(root,"EXECUTION_COMPLETED",{"executionId":execution_id,"status":result["status"],"receiptHash":result["receiptHash"]},pol["audit"]["required"])
        return result
    finally:
        fcntl.flock(comp_lock,fcntl.LOCK_UN);os.close(comp_lock)
        if idem_lock is not None:fcntl.flock(idem_lock,fcntl.LOCK_UN);os.close(idem_lock)

def main():
    ap=argparse.ArgumentParser();ap.add_argument("--root",required=True,type=Path)
    ap.add_argument("command",choices=["run","validate","reconcile"])
    args=ap.parse_args()
    req={}
    try:
        root=args.root
        reject_symlink_chain(root,True)
        if args.command=="reconcile":
            print(json.dumps(reconcile(root),indent=2));return
        pol=load_json(root/"config/execution/policy-v2.json")
        raw=sys.stdin.buffer.read(pol["maxRequestBytes"]+1)
        if len(raw)>pol["maxRequestBytes"]:raise Invalid("request too large")
        req=json.loads(raw)
        strict_validate(req,pol)
        if args.command=="validate":
            print(json.dumps({"status":"VALID"},indent=2));return
        result=execute(root,req)
        print(json.dumps(result,indent=2,sort_keys=True))
        if result["status"] in ("SUCCESS","DRY_RUN"):raise SystemExit(0)
        if result["status"]=="TIMEOUT":raise SystemExit(18)
        raise SystemExit(1)
    except EIFError as e:
        try: denial(args.root,req,e)
        except Exception:pass
        print(json.dumps({"status":"ERROR","error":type(e).__name__,"message":str(e)}),file=sys.stderr)
        raise SystemExit(e.code)
    except Exception as e:
        try: denial(args.root,req,e)
        except Exception:pass
        print(json.dumps({"status":"ERROR","error":"Unexpected","message":str(e)}),file=sys.stderr)
        raise SystemExit(8)
if __name__=="__main__":main()
