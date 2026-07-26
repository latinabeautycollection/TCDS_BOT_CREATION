#!/usr/bin/env python3
from __future__ import annotations
import argparse, contextlib, datetime as dt, fcntl, hashlib, json, os, pwd, grp
import shutil, socket, stat, subprocess, sys, tempfile, uuid
from pathlib import Path
from typing import Any, Dict, Iterable, List

VERSION = "0.3.0"
STATES = ["NEW","DISCOVERED","STAGED","INSTALLED","CONFIGURED","VALIDATED",
          "HEALTHY","FAILED","ROLLING_BACK","ROLLED_BACK","REMOVED"]
ALLOWED = {
 "NEW":{"DISCOVERED","FAILED","REMOVED"},
 "DISCOVERED":{"STAGED","FAILED","REMOVED"},
 "STAGED":{"INSTALLED","FAILED","ROLLING_BACK"},
 "INSTALLED":{"CONFIGURED","VALIDATED","FAILED","ROLLING_BACK"},
 "CONFIGURED":{"VALIDATED","FAILED","ROLLING_BACK"},
 "VALIDATED":{"HEALTHY","FAILED","ROLLING_BACK"},
 "HEALTHY":{"STAGED","CONFIGURED","VALIDATED","FAILED","REMOVED"},
 "FAILED":{"ROLLING_BACK","STAGED","REMOVED"},
 "ROLLING_BACK":{"ROLLED_BACK","FAILED"},
 "ROLLED_BACK":{"STAGED","REMOVED"},
 "REMOVED":set(),
}
SECRET_SCHEMES = {"env","file","vault","aws","azure","gcp"}

class EIFError(Exception):
    exit_code = 8
class Collision(EIFError): exit_code = 3
class Validation(EIFError): exit_code = 6
class Locked(EIFError): exit_code = 7
class Drift(EIFError): exit_code = 10
class TransactionError(EIFError): exit_code = 11
class RegistryError(EIFError): exit_code = 12
class StateError(EIFError): exit_code = 13
class UpgradeError(EIFError): exit_code = 14

def utc() -> str:
    return dt.datetime.now(dt.timezone.utc).replace(microsecond=0).isoformat().replace("+00:00","Z")

def canonical(obj: Any) -> bytes:
    return (json.dumps(obj, sort_keys=True, separators=(",",":")) + "\n").encode()

def sha256_file(path: Path) -> str:
    h=hashlib.sha256()
    with path.open("rb") as f:
        for chunk in iter(lambda:f.read(1024*1024), b""): h.update(chunk)
    return h.hexdigest()

def load_json(path: Path, required=True) -> Any:
    if path.is_symlink(): raise Collision(f"symlink refused: {path}")
    if not path.exists():
        if required: raise Validation(f"missing JSON: {path}")
        return {}
    try: return json.loads(path.read_text(encoding="utf-8"))
    except json.JSONDecodeError as e: raise Validation(f"invalid JSON {path}: {e}")

def atomic_write(path: Path, data: bytes, mode=0o640, overwrite=True) -> None:
    path.parent.mkdir(parents=True, exist_ok=True, mode=0o750)
    if path.is_symlink(): raise Collision(f"symlink refused: {path}")
    if path.exists() and not overwrite:
        if path.read_bytes() == data: return
        raise Collision(f"immutable collision: {path}")
    fd,tmp=tempfile.mkstemp(prefix=f".{path.name}.", dir=path.parent)
    try:
        os.fchmod(fd, mode)
        with os.fdopen(fd,"wb") as f:
            f.write(data); f.flush(); os.fsync(f.fileno())
        os.replace(tmp,path)
        dfd=os.open(path.parent, os.O_DIRECTORY)
        try: os.fsync(dfd)
        finally: os.close(dfd)
    finally:
        if os.path.exists(tmp): os.unlink(tmp)

def event(root: Path, event_type: str, **fields: Any) -> Dict[str,Any]:
    e={"schemaVersion":"1.0","eventId":str(uuid.uuid4()),"timestampUtc":utc(),
       "type":event_type,"host":socket.gethostname(),"frameworkVersion":VERSION,**fields}
    day=dt.datetime.now(dt.timezone.utc).strftime("%Y-%m-%d")
    path=root/"events"/f"{day}.jsonl"
    path.parent.mkdir(parents=True,exist_ok=True,mode=0o750)
    flags=os.O_APPEND|os.O_CREAT|os.O_WRONLY
    fd=os.open(path,flags,0o640)
    try:
        fcntl.flock(fd,fcntl.LOCK_EX)
        os.write(fd,canonical(e))
        os.fsync(fd)
    finally:
        os.close(fd)
    return e

@contextlib.contextmanager
def lock(path: Path, wait_seconds: int=0):
    path.parent.mkdir(parents=True,exist_ok=True,mode=0o750)
    fd=os.open(path,os.O_CREAT|os.O_RDWR,0o640)
    try:
        flags=fcntl.LOCK_EX | (fcntl.LOCK_NB if wait_seconds==0 else 0)
        try: fcntl.flock(fd,flags)
        except BlockingIOError: raise Locked(f"lock busy: {path}")
        os.ftruncate(fd,0)
        os.write(fd,canonical({"pid":os.getpid(),"host":socket.gethostname(),"acquiredAtUtc":utc()}))
        yield
    finally:
        try: fcntl.flock(fd,fcntl.LOCK_UN)
        finally: os.close(fd)

def validate_component(c: Dict[str,Any]) -> None:
    required=["name","versionPolicy","dependencies","lifecycle","contracts"]
    for k in required:
        if k not in c: raise RegistryError(f"component missing {k}")
    if not isinstance(c["name"],str) or not c["name"]: raise RegistryError("invalid name")
    if not isinstance(c["dependencies"],list): raise RegistryError("dependencies must be array")
    for section in ("installer","configurator","validator","rollback","health"):
        if section not in c["contracts"]: raise RegistryError(f"missing contract: {section}")

def registry_build(root: Path) -> Dict[str,Any]:
    comps={}
    for p in sorted((root/"registry/components").glob("*.json")):
        doc=load_json(p)
        c=doc.get("component",doc)
        validate_component(c)
        name=c["name"]
        if name in comps: raise RegistryError(f"duplicate component: {name}")
        comps[name]={"definition":str(p.relative_to(root)),"sha256":sha256_file(p),**c}
    # Validate dependencies and cycles.
    for name,c in comps.items():
        for dep in c["dependencies"]:
            if dep not in comps: raise RegistryError(f"{name}: unknown dependency {dep}")
    visiting,visited=set(),set()
    def visit(n):
        if n in visiting: raise RegistryError(f"dependency cycle at {n}")
        if n in visited:return
        visiting.add(n)
        for d in comps[n]["dependencies"]: visit(d)
        visiting.remove(n); visited.add(n)
    for n in comps: visit(n)
    result={"schemaVersion":"1.0","generatedAtUtc":utc(),"frameworkVersion":VERSION,
            "componentCount":len(comps),"components":comps}
    atomic_write(root/"registry/registry.json",canonical(result))
    event(root,"REGISTRY_BUILT",componentCount=len(comps))
    return result

def registry_order(root: Path, names: List[str]) -> List[str]:
    reg=load_json(root/"registry/registry.json")
    comps=reg["components"]; ordered=[]; seen=set()
    def add(n):
        if n not in comps: raise RegistryError(f"unknown component: {n}")
        if n in seen:return
        for d in comps[n]["dependencies"]: add(d)
        seen.add(n); ordered.append(n)
    for n in names:add(n)
    return ordered

def state_get(root: Path, component: str) -> Dict[str,Any]:
    p=root/"state/components"/f"{component}.json"
    return load_json(p,required=False) or {"component":component,"state":"NEW","history":[]}

def state_transition(root: Path, component: str, target: str, reason: str, force=False) -> Dict[str,Any]:
    if target not in STATES: raise StateError(f"unknown target state: {target}")
    p=root/"state/components"/f"{component}.json"
    with lock(root/"state/locks"/f"component-{component}.lock"):
        doc=state_get(root,component); current=doc["state"]
        if not force and target not in ALLOWED[current]:
            raise StateError(f"invalid transition {current}->{target}")
        rec={"from":current,"to":target,"reason":reason,"atUtc":utc(),
             "runId":os.environ.get("EIF_RUN_ID","unknown")}
        doc["state"]=target; doc["updatedAtUtc"]=rec["atUtc"]; doc.setdefault("history",[]).append(rec)
        atomic_write(p,canonical(doc))
        event(root,"STATE_TRANSITION",component=component,fromState=current,toState=target,reason=reason)
        return doc

def file_metadata(path: Path) -> Dict[str,Any]:
    if path.is_symlink(): return {"path":str(path),"type":"symlink"}
    if not path.exists(): return {"path":str(path),"type":"missing"}
    st=path.stat()
    mode=stat.S_IMODE(st.st_mode)
    data={"path":str(path),"type":"file" if path.is_file() else "directory",
          "mode":format(mode,"04o"),"uid":st.st_uid,"gid":st.st_gid,
          "owner":pwd.getpwuid(st.st_uid).pw_name,"group":grp.getgrgid(st.st_gid).gr_name,
          "mtimeNs":st.st_mtime_ns}
    if path.is_file(): data["sha256"]=sha256_file(path)
    getfacl=shutil.which("getfacl")
    if getfacl:
        r=subprocess.run([getfacl,"-cp",str(path)],capture_output=True,text=True)
        if r.returncode==0:data["aclSha256"]=hashlib.sha256(r.stdout.encode()).hexdigest()
    getcap=shutil.which("getcap")
    if getcap:
        r=subprocess.run([getcap,"-n",str(path)],capture_output=True,text=True)
        if r.returncode==0:data["capabilities"]=r.stdout.strip()
    aa=shutil.which("aa-status")
    data["apparmorAvailable"]=bool(aa)
    return data

def inventory(root: Path, component: str|None=None) -> Dict[str,Any]:
    reg=load_json(root/"registry/registry.json")
    names=[component] if component else sorted(reg["components"])
    result={"schemaVersion":"1.0","generatedAtUtc":utc(),"host":socket.gethostname(),
            "frameworkVersion":VERSION,"components":{}}
    for n in names:
        c=reg["components"][n]
        inv={"state":state_get(root,n)["state"],"definitionSha256":c["sha256"],
             "dependencies":c["dependencies"],"packages":[],"services":[],"ports":[],
             "certificates":[],"files":[]}
        disc=c.get("inventory",{})
        for package in disc.get("packages",[]):
            r=subprocess.run(["dpkg-query","-W","-f=${Status}|${Version}",package],
                             capture_output=True,text=True)
            inv["packages"].append({"name":package,"installed":r.returncode==0,
                                    "detail":r.stdout.strip() if r.returncode==0 else None})
        for svc in disc.get("services",[]):
            if shutil.which("systemctl"):
                r=subprocess.run(["systemctl","is-active",svc],capture_output=True,text=True)
                inv["services"].append({"name":svc,"active":r.returncode==0,"status":r.stdout.strip()})
        inv["ports"]=disc.get("ports",[])
        inv["certificates"]=disc.get("certificates",[])
        for p in disc.get("files",[]): inv["files"].append(file_metadata(Path(p)))
        result["components"][n]=inv
    path=root/"inventory"/"inventory.json"
    atomic_write(path,canonical(result))
    event(root,"INVENTORY_CREATED",component=component or "all")
    return result

def baseline(root: Path, paths: Iterable[str], name: str) -> Dict[str,Any]:
    doc={"schemaVersion":"1.0","name":name,"createdAtUtc":utc(),
         "files":[file_metadata(Path(p)) for p in paths]}
    atomic_write(root/"inventory/baselines"/f"{name}.json",canonical(doc),overwrite=False)
    event(root,"DRIFT_BASELINE_CREATED",baseline=name,fileCount=len(doc["files"]))
    return doc

def drift_check(root: Path, name: str) -> Dict[str,Any]:
    b=load_json(root/"inventory/baselines"/f"{name}.json")
    changes=[]
    for old in b["files"]:
        new=file_metadata(Path(old["path"]))
        keys=("type","mode","uid","gid","sha256","aclSha256","capabilities")
        diff={k:{"expected":old.get(k),"actual":new.get(k)} for k in keys if old.get(k)!=new.get(k)}
        if diff: changes.append({"path":old["path"],"differences":diff})
    doc={"schemaVersion":"1.0","baseline":name,"checkedAtUtc":utc(),
         "drift":bool(changes),"changes":changes}
    atomic_write(root/"inventory/reports"/f"drift-{name}.json",canonical(doc))
    event(root,"DRIFT_CHECKED",baseline=name,drift=bool(changes),changeCount=len(changes))
    if changes: raise Drift(json.dumps(doc))
    return doc

def secret_parse(ref: str) -> Dict[str,str]:
    if not ref.startswith("secret://"): raise Validation("not a secret reference")
    rest=ref[len("secret://"):]
    scheme,sep,target=rest.partition("/")
    if not sep or scheme not in SECRET_SCHEMES or not target:
        raise Validation(f"invalid secret reference: {ref}")
    return {"scheme":scheme,"target":target}

def secret_resolve(ref: str, allow_external=False) -> str:
    s=secret_parse(ref); scheme=s["scheme"]; target=s["target"]
    if scheme=="env":
        if target not in os.environ: raise Validation(f"missing env secret: {target}")
        return os.environ[target]
    if scheme=="file":
        p=Path("/"+target.lstrip("/"))
        if not p.is_absolute() or p.is_symlink() or not p.is_file():
            raise Validation(f"unsafe secret file: {p}")
        if stat.S_IMODE(p.stat().st_mode) & 0o077:
            raise Validation(f"secret file permissions too broad: {p}")
        return p.read_text(encoding="utf-8").rstrip("\n")
    if not allow_external:
        raise Validation(f"external provider disabled: {scheme}")
    raise Validation(f"provider adapter not configured: {scheme}")

def transaction_begin(root: Path, component: str, operation: str) -> Dict[str,Any]:
    tid=str(uuid.uuid4()); p=root/"state/transactions"/f"{tid}.json"
    doc={"transactionId":tid,"component":component,"operation":operation,"state":"BEGIN",
         "startedAtUtc":utc(),"runId":os.environ.get("EIF_RUN_ID","unknown"),
         "checkpoints":[],"actions":[]}
    atomic_write(p,canonical(doc),overwrite=False)
    event(root,"TRANSACTION_STARTED",transactionId=tid,component=component,operation=operation)
    return doc

def transaction_update(root: Path, tid: str, action: str, status: str, detail="") -> Dict[str,Any]:
    p=root/"state/transactions"/f"{tid}.json"
    with lock(root/"state/locks"/f"transaction-{tid}.lock"):
        d=load_json(p); d["actions"].append({"action":action,"status":status,"detail":detail,"atUtc":utc()})
        d["updatedAtUtc"]=utc(); atomic_write(p,canonical(d)); return d

def transaction_finish(root: Path, tid: str, status: str) -> Dict[str,Any]:
    if status not in {"COMMITTED","ROLLED_BACK","FAILED"}: raise TransactionError("invalid finish state")
    p=root/"state/transactions"/f"{tid}.json"
    with lock(root/"state/locks"/f"transaction-{tid}.lock"):
        d=load_json(p); d["state"]=status; d["finishedAtUtc"]=utc()
        atomic_write(p,canonical(d))
        event(root,f"TRANSACTION_{status}",transactionId=tid,component=d["component"])
        return d

def doctor(root: Path) -> Dict[str,Any]:
    checks=[]
    def add(name,ok,detail): checks.append({"name":name,"status":"PASS" if ok else "FAIL","detail":detail})
    add("root-not-symlink",not root.is_symlink(),str(root))
    add("framework-version",(root/"VERSION").read_text().strip()==VERSION if (root/"VERSION").exists() else False,VERSION)
    for d in ("registry","state","events","inventory","plugins","migrations"):
        p=root/d; add(f"directory-{d}",p.is_dir() and not p.is_symlink(),str(p))
    try:
        reg=registry_build(root); add("registry-valid",True,f'{reg["componentCount"]} components')
    except Exception as e:add("registry-valid",False,str(e))
    for p in root.rglob("*"):
        if p.is_symlink(): add("no-framework-symlinks",False,str(p)); break
    else:add("no-framework-symlinks",True,"none")
    add("python-version",sys.version_info >= (3,10),sys.version.split()[0])
    result={"schemaVersion":"1.0","checkedAtUtc":utc(),"frameworkVersion":VERSION,
            "status":"PASS" if all(x["status"]=="PASS" for x in checks) else "FAIL","checks":checks}
    atomic_write(root/"inventory/reports"/"doctor.json",canonical(result))
    event(root,"DOCTOR_COMPLETED",status=result["status"])
    return result

def migration_plan(root: Path, current: str, target: str) -> List[Path]:
    found=[]
    for p in sorted((root/"migrations").glob("*.json")):
        m=load_json(p)
        if m.get("from")==current: found.append(p); current=m.get("to")
        if current==target:return found
    if current!=target: raise UpgradeError(f"no migration path to {target}")
    return found

def main():
    p=argparse.ArgumentParser()
    p.add_argument("--root",required=True,type=Path)
    sub=p.add_subparsers(dest="cmd",required=True)
    sub.add_parser("registry-build")
    q=sub.add_parser("registry-order"); q.add_argument("components",nargs="+")
    q=sub.add_parser("state-get"); q.add_argument("component")
    q=sub.add_parser("state-transition"); q.add_argument("component"); q.add_argument("target"); q.add_argument("--reason",required=True); q.add_argument("--force",action="store_true")
    q=sub.add_parser("event"); q.add_argument("type"); q.add_argument("--component"); q.add_argument("--detail")
    q=sub.add_parser("inventory"); q.add_argument("--component")
    q=sub.add_parser("baseline"); q.add_argument("--name",required=True); q.add_argument("paths",nargs="+")
    q=sub.add_parser("drift"); q.add_argument("--name",required=True)
    q=sub.add_parser("secret-validate"); q.add_argument("reference")
    q=sub.add_parser("transaction-begin"); q.add_argument("component"); q.add_argument("operation")
    q=sub.add_parser("transaction-update"); q.add_argument("transaction"); q.add_argument("action"); q.add_argument("status"); q.add_argument("--detail",default="")
    q=sub.add_parser("transaction-finish"); q.add_argument("transaction"); q.add_argument("status")
    sub.add_parser("doctor")
    args=p.parse_args(); root=args.root.resolve()
    try:
        if args.cmd=="registry-build": result=registry_build(root)
        elif args.cmd=="registry-order": result=registry_order(root,args.components)
        elif args.cmd=="state-get": result=state_get(root,args.component)
        elif args.cmd=="state-transition": result=state_transition(root,args.component,args.target,args.reason,args.force)
        elif args.cmd=="event": result=event(root,args.type,component=args.component,detail=args.detail)
        elif args.cmd=="inventory": result=inventory(root,args.component)
        elif args.cmd=="baseline": result=baseline(root,args.paths,args.name)
        elif args.cmd=="drift": result=drift_check(root,args.name)
        elif args.cmd=="secret-validate": result=secret_parse(args.reference)
        elif args.cmd=="transaction-begin": result=transaction_begin(root,args.component,args.operation)
        elif args.cmd=="transaction-update": result=transaction_update(root,args.transaction,args.action,args.status,args.detail)
        elif args.cmd=="transaction-finish": result=transaction_finish(root,args.transaction,args.status)
        elif args.cmd=="doctor": result=doctor(root)
        print(json.dumps(result,indent=2,sort_keys=True))
    except EIFError as e:
        print(json.dumps({"status":"ERROR","error":type(e).__name__,"message":str(e)}),file=sys.stderr)
        raise SystemExit(e.exit_code)

if __name__=="__main__": main()
