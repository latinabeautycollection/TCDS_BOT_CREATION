#!/usr/bin/env python3
from __future__ import annotations
import argparse, contextlib, datetime as dt, fcntl, hashlib, json, os, socket, stat, sys, tempfile, uuid
from pathlib import Path

VERSION="0.8.0"
ID_RE=__import__("re").compile(r"^[A-Za-z0-9][A-Za-z0-9._:-]{0,127}$")
TX_TRANSITIONS={
"NEW":{"PREPARED","FAILED"},"PREPARED":{"APPLYING","FAILED","ROLLBACK_PENDING"},
"APPLYING":{"VALIDATING","FAILED","ROLLBACK_PENDING"},"VALIDATING":{"COMMITTING","FAILED","ROLLBACK_PENDING"},
"COMMITTING":{"COMMITTED","FAILED","RECOVERY_REQUIRED"},"FAILED":{"ROLLBACK_PENDING","ABANDONED","RECOVERY_REQUIRED"},
"ROLLBACK_PENDING":{"ROLLING_BACK","ABANDONED"},"ROLLING_BACK":{"ROLLED_BACK","RECOVERY_REQUIRED"},
"ROLLED_BACK":{"PREPARED","ABANDONED"},"RECOVERY_REQUIRED":{"ROLLBACK_PENDING","ABANDONED"},
"COMMITTED":set(),"ABANDONED":set()}
COMP_TRANSITIONS={
"NEW":{"DISCOVERED","REMOVED"},"DISCOVERED":{"STAGED","FAILED","REMOVED"},
"STAGED":{"INSTALLED","FAILED","ROLLING_BACK"},"INSTALLED":{"CONFIGURED","VALIDATED","FAILED","ROLLING_BACK"},
"CONFIGURED":{"VALIDATED","FAILED","ROLLING_BACK"},"VALIDATED":{"HEALTHY","DEGRADED","FAILED","ROLLING_BACK"},
"HEALTHY":{"STAGED","CONFIGURED","VALIDATED","DEGRADED","FAILED","REMOVED"},
"DEGRADED":{"VALIDATED","HEALTHY","FAILED","ROLLING_BACK"},"FAILED":{"STAGED","ROLLING_BACK","REMOVED"},
"ROLLING_BACK":{"ROLLED_BACK","FAILED"},"ROLLED_BACK":{"STAGED","REMOVED"},"REMOVED":set()}
class E(Exception): code=8
class Validation(E): code=6
class Locked(E): code=7
class Recovery(E): code=19
class Conflict(E): code=20
class Checkpoint(E): code=21
def utc(): return dt.datetime.now(dt.timezone.utc).isoformat(timespec="milliseconds").replace("+00:00","Z")
def canon(x): return (json.dumps(x,sort_keys=True,separators=(",",":"))+"\n").encode()
def digest(b): return hashlib.sha256(b).hexdigest()
def valid(v,n):
    if not isinstance(v,str) or not ID_RE.fullmatch(v): raise Validation(f"invalid {n}")
    return v
def root_ok(p):
    if not p.is_absolute() or p.is_symlink(): raise Validation("unsafe root")
    cur=p
    while cur!=cur.parent:
        if cur.is_symlink(): raise Validation(f"symlink path component: {cur}")
        cur=cur.parent
    return p
def beneath(root,p):
    r=root.resolve(strict=False); q=p.resolve(strict=False)
    if q!=r and r not in q.parents: raise Validation("path escape")
def atomic(root,p,data,mode=0o640,overwrite=True):
    beneath(root,p); p.parent.mkdir(parents=True,exist_ok=True,mode=0o750)
    if p.is_symlink(): raise Validation(f"symlink refused: {p}")
    if p.exists() and not overwrite and p.read_bytes()!=data: raise Conflict(f"immutable collision: {p}")
    fd,tmp=tempfile.mkstemp(prefix=f".{p.name}.",dir=p.parent)
    try:
        os.fchmod(fd,mode)
        with os.fdopen(fd,"wb") as f: f.write(data); f.flush(); os.fsync(f.fileno())
        os.replace(tmp,p)
        dfd=os.open(p.parent,os.O_DIRECTORY)
        try: os.fsync(dfd)
        finally: os.close(dfd)
    finally:
        if os.path.exists(tmp): os.unlink(tmp)
@contextlib.contextmanager
def locked(p):
    p.parent.mkdir(parents=True,exist_ok=True,mode=0o750)
    fd=os.open(p,os.O_CREAT|os.O_RDWR|os.O_NOFOLLOW,0o640)
    try:
        try: fcntl.flock(fd,fcntl.LOCK_EX|fcntl.LOCK_NB)
        except BlockingIOError: raise Locked(f"lock busy: {p}")
        yield
    finally:
        try: fcntl.flock(fd,fcntl.LOCK_UN)
        finally: os.close(fd)
def load(p,required=True):
    if p.is_symlink(): raise Validation(f"symlink refused: {p}")
    if not p.exists():
        if required: raise Validation(f"missing: {p}")
        return None
    try:return json.loads(p.read_text())
    except Exception as ex: raise Validation(f"invalid JSON {p}: {ex}")
def append_journal(root,kind,data):
    p=root/"state/transactions/journal.jsonl"; lp=root/"state/locks/transaction-journal.lock"
    with locked(lp):
        prev="0"*64; seq=1
        if p.exists():
            for line in p.read_text().splitlines():
                if line.strip():
                    row=json.loads(line); prev=row["entryHash"]; seq=row["sequence"]+1
        row={"schemaVersion":"1.0","sequence":seq,"timestampUtc":utc(),"kind":kind,"previousHash":prev,**data}
        row["entryHash"]=digest(canon(row))
        fd=os.open(p,os.O_APPEND|os.O_CREAT|os.O_WRONLY|os.O_NOFOLLOW,0o640)
        try: os.write(fd,canon(row)); os.fsync(fd)
        finally: os.close(fd)
    return row
def comp_file(root,c): return root/"state/components"/f"{digest(c.encode())}.json"
def tx_file(root,t): return root/"state/transactions"/f"{t}.json"
def comp_get(root,c):
    valid(c,"component"); return load(comp_file(root,c),False) or {"schemaVersion":"1.0","component":c,"state":"NEW","version":0,"history":[]}
def comp_transition(root,c,target,reason,expected=None):
    valid(c,"component"); valid(target,"target")
    if target not in COMP_TRANSITIONS: raise Validation("unknown component state")
    with locked(root/"state/locks"/f"component-{digest(c.encode())}.lock"):
        d=comp_get(root,c)
        if expected is not None and d["version"]!=expected: raise Conflict("component version conflict")
        cur=d["state"]
        if target not in COMP_TRANSITIONS[cur]: raise Conflict(f"invalid transition {cur}->{target}")
        rec={"from":cur,"to":target,"reason":reason,"atUtc":utc()}
        d["state"]=target; d["version"]+=1; d["updatedAtUtc"]=rec["atUtc"]; d["history"].append(rec)
        atomic(root,comp_file(root,c),canon(d)); append_journal(root,"COMPONENT_STATE_CHANGED",{"component":c,"fromState":cur,"toState":target,"version":d["version"]})
        return d
def tx_begin(root,component,operation,change,key,strategy):
    for v,n in [(component,"component"),(operation,"operation"),(change,"change_id"),(key,"idempotency_key")]: valid(v,n)
    kd=digest(key.encode())
    with locked(root/"state/locks"/f"tx-idem-{kd}.lock"):
        idx=root/"state/transactions/idempotency"/f"{kd}.json"; old=load(idx,False)
        if old:return load(tx_file(root,old["transactionId"]))
        tid=str(uuid.uuid4())
        d={"schemaVersion":"1.0","transactionId":tid,"component":component,"operation":operation,"changeId":change,
           "idempotencyKeyDigest":kd,"rollbackStrategy":strategy,"state":"NEW","version":0,
           "createdAtUtc":utc(),"updatedAtUtc":utc(),"host":socket.gethostname(),
           "runId":os.getenv("EIF_RUN_ID","unknown"),"correlationId":os.getenv("EIF_CORRELATION_ID","unknown"),
           "checkpoints":[],"actions":[],"errors":[]}
        atomic(root,tx_file(root,tid),canon(d),overwrite=False)
        atomic(root,idx,canon({"transactionId":tid}),overwrite=False)
        append_journal(root,"TRANSACTION_CREATED",{"transactionId":tid,"component":component,"operation":operation})
        return d
def tx_get(root,tid): valid(tid,"transactionId"); return load(tx_file(root,tid))
def tx_transition(root,tid,target,reason,expected=None):
    valid(tid,"transactionId")
    if target not in TX_TRANSITIONS: raise Validation("unknown transaction state")
    with locked(root/"state/locks"/f"transaction-{tid}.lock"):
        d=tx_get(root,tid)
        if expected is not None and d["version"]!=expected: raise Conflict("transaction version conflict")
        cur=d["state"]
        if target not in TX_TRANSITIONS[cur]: raise Conflict(f"invalid transition {cur}->{target}")
        d["state"]=target; d["version"]+=1; d["updatedAtUtc"]=utc()
        d["actions"].append({"type":"STATE_TRANSITION","from":cur,"to":target,"reason":reason,"atUtc":d["updatedAtUtc"]})
        atomic(root,tx_file(root,tid),canon(d)); append_journal(root,"TRANSACTION_STATE_CHANGED",{"transactionId":tid,"fromState":cur,"toState":target,"version":d["version"]})
        return d
def checkpoint_create(root,tid,name,paths):
    valid(tid,"transactionId"); valid(name,"checkpoint")
    d=tx_get(root,tid)
    if d["state"] not in {"PREPARED","APPLYING","ROLLBACK_PENDING","ROLLING_BACK"}: raise Conflict("checkpoint not allowed")
    cd=root/"state/checkpoints"/tid/name
    if cd.exists(): raise Conflict("checkpoint exists")
    cd.mkdir(parents=True,mode=0o750)
    m={"schemaVersion":"1.0","transactionId":tid,"checkpoint":name,"createdAtUtc":utc(),"entries":[]}
    for raw in paths:
        p=Path(raw)
        if not p.is_absolute(): raise Validation("checkpoint path must be absolute")
        if p.is_symlink(): raise Checkpoint(f"symlink refused: {p}")
        e={"source":str(p)}
        if not p.exists(): e["type"]="missing"
        elif p.is_file():
            data=p.read_bytes(); namehash=digest(str(p).encode()); blob=cd/f"{namehash}.blob"
            st=p.stat(); atomic(root,blob,data,stat.S_IMODE(st.st_mode),False)
            e.update({"type":"file","blob":blob.name,"sha256":digest(data),"mode":stat.S_IMODE(st.st_mode),"uid":st.st_uid,"gid":st.st_gid})
        elif p.is_dir(): e.update({"type":"directory","mode":stat.S_IMODE(p.stat().st_mode)})
        else: raise Checkpoint(f"unsupported type: {p}")
        m["entries"].append(e)
    m["manifestHash"]=digest(canon(m)); atomic(root,cd/"manifest.json",canon(m),overwrite=False)
    d["checkpoints"].append({"name":name,"manifestHash":m["manifestHash"]}); atomic(root,tx_file(root,tid),canon(d))
    append_journal(root,"CHECKPOINT_CREATED",{"transactionId":tid,"checkpoint":name,"manifestHash":m["manifestHash"]})
    return m
def checkpoint_verify(root,tid,name):
    m=load(root/"state/checkpoints"/tid/name/"manifest.json"); recorded=m.pop("manifestHash")
    if digest(canon(m))!=recorded: raise Checkpoint("manifest hash mismatch")
    for e in m["entries"]:
        if e["type"]=="file":
            b=root/"state/checkpoints"/tid/name/e["blob"]
            if b.is_symlink() or not b.is_file() or digest(b.read_bytes())!=e["sha256"]: raise Checkpoint("blob verification failed")
    return {"status":"PASS","entryCount":len(m["entries"]),"manifestHash":recorded}
def checkpoint_restore(root,tid,name,dry=False):
    cp=root/"state/checkpoints"/tid/name; m=load(cp/"manifest.json"); recorded=m.pop("manifestHash")
    if digest(canon(m))!=recorded: raise Checkpoint("manifest hash mismatch")
    actions=[]
    for e in m["entries"]:
        target=Path(e["source"])
        if target.is_symlink(): raise Checkpoint(f"target symlink refused: {target}")
        if e["type"]=="missing":
            actions.append({"action":"REMOVE_CREATED","path":str(target)})
            if not dry and target.exists():
                if target.is_file(): target.unlink()
                else: raise Checkpoint("refuse non-file removal")
        elif e["type"]=="directory":
            actions.append({"action":"ENSURE_DIRECTORY","path":str(target)})
            if not dry: target.mkdir(parents=True,exist_ok=True,mode=e["mode"])
        else:
            b=cp/e["blob"]
            if digest(b.read_bytes())!=e["sha256"]: raise Checkpoint("blob corrupted")
            actions.append({"action":"RESTORE_FILE","path":str(target)})
            if not dry:
                target.parent.mkdir(parents=True,exist_ok=True)
                fd,tmp=tempfile.mkstemp(prefix=f".{target.name}.restore.",dir=target.parent)
                try:
                    os.fchmod(fd,e["mode"])
                    with os.fdopen(fd,"wb") as f: f.write(b.read_bytes()); f.flush(); os.fsync(f.fileno())
                    try: os.chown(tmp,e["uid"],e["gid"])
                    except PermissionError: pass
                    os.replace(tmp,target)
                finally:
                    if os.path.exists(tmp): os.unlink(tmp)
    append_journal(root,"CHECKPOINT_RESTORED",{"transactionId":tid,"checkpoint":name,"dryRun":dry})
    return {"status":"DRY_RUN" if dry else "RESTORED","actions":actions}
def reconcile(root):
    out=[]
    for p in sorted((root/"state/transactions").glob("*.json")):
        d=load(p)
        if d.get("state") in {"APPLYING","VALIDATING","COMMITTING","ROLLING_BACK"}:
            d["state"]="RECOVERY_REQUIRED"; d["version"]+=1; d["updatedAtUtc"]=utc()
            d["errors"].append({"code":"INTERRUPTED_TRANSACTION","atUtc":d["updatedAtUtc"]})
            atomic(root,p,canon(d)); append_journal(root,"TRANSACTION_RECOVERY_REQUIRED",{"transactionId":d["transactionId"]})
            out.append({"transactionId":d["transactionId"],"state":"RECOVERY_REQUIRED"})
    return {"status":"PASS","count":len(out),"reconciled":out}
def verify_journal(root):
    p=root/"state/transactions/journal.jsonl"
    if not p.exists(): return {"status":"PASS","entries":0}
    prev="0"*64; count=0
    for i,line in enumerate(p.read_text().splitlines(),1):
        row=json.loads(line); h=row.pop("entryHash")
        if row["sequence"]!=i or row["previousHash"]!=prev or digest(canon(row))!=h: raise Validation(f"journal failure line {i}")
        prev=h; count=i
    return {"status":"PASS","entries":count,"lastHash":prev}
def main():
    a=argparse.ArgumentParser(); a.add_argument("--root",required=True,type=Path); s=a.add_subparsers(dest="cmd",required=True)
    p=s.add_parser("component-get"); p.add_argument("component")
    p=s.add_parser("component-transition"); p.add_argument("component"); p.add_argument("target"); p.add_argument("--reason",required=True); p.add_argument("--expected-version",type=int)
    p=s.add_parser("tx-begin"); p.add_argument("component"); p.add_argument("operation"); p.add_argument("change_id"); p.add_argument("idempotency_key"); p.add_argument("--rollback-strategy",default="checkpoint")
    p=s.add_parser("tx-get"); p.add_argument("transaction_id")
    p=s.add_parser("tx-transition"); p.add_argument("transaction_id"); p.add_argument("target"); p.add_argument("--reason",required=True); p.add_argument("--expected-version",type=int)
    p=s.add_parser("checkpoint-create"); p.add_argument("transaction_id"); p.add_argument("name"); p.add_argument("paths",nargs="+")
    p=s.add_parser("checkpoint-verify"); p.add_argument("transaction_id"); p.add_argument("name")
    p=s.add_parser("checkpoint-restore"); p.add_argument("transaction_id"); p.add_argument("name"); p.add_argument("--dry-run",action="store_true")
    s.add_parser("reconcile"); s.add_parser("verify-journal")
    x=a.parse_args(); r=root_ok(x.root)
    try:
        if x.cmd=="component-get": out=comp_get(r,x.component)
        elif x.cmd=="component-transition": out=comp_transition(r,x.component,x.target,x.reason,x.expected_version)
        elif x.cmd=="tx-begin": out=tx_begin(r,x.component,x.operation,x.change_id,x.idempotency_key,x.rollback_strategy)
        elif x.cmd=="tx-get": out=tx_get(r,x.transaction_id)
        elif x.cmd=="tx-transition": out=tx_transition(r,x.transaction_id,x.target,x.reason,x.expected_version)
        elif x.cmd=="checkpoint-create": out=checkpoint_create(r,x.transaction_id,x.name,x.paths)
        elif x.cmd=="checkpoint-verify": out=checkpoint_verify(r,x.transaction_id,x.name)
        elif x.cmd=="checkpoint-restore": out=checkpoint_restore(r,x.transaction_id,x.name,x.dry_run)
        elif x.cmd=="reconcile": out=reconcile(r)
        else: out=verify_journal(r)
        print(json.dumps(out,indent=2,sort_keys=True))
    except E as ex:
        print(json.dumps({"status":"ERROR","error":type(ex).__name__,"message":str(ex)}),file=sys.stderr)
        raise SystemExit(ex.code)
if __name__=="__main__": main()
