#!/usr/bin/env python3
from __future__ import annotations
import argparse, base64, contextlib, datetime as dt, fcntl, hashlib, hmac, json, os, shutil, socket, sqlite3, stat, subprocess, sys, tempfile, uuid
from pathlib import Path
from typing import Any, Iterable
import jsonschema

VERSION="1.1.0"
ID_RE=__import__("re").compile(r"^[A-Za-z0-9][A-Za-z0-9._:-]{0,127}$")
HASH_RE=__import__("re").compile(r"^[a-f0-9]{64}$")
class BError(Exception): code=8
class Validation(BError): code=6
class Locked(BError): code=7
class Conflict(BError): code=20
class Integrity(BError): code=22
class Eligibility(BError): code=23
class Approval(BError): code=24
class Encryption(BError): code=25
class RemoteExport(BError): code=26
class TransactionRequired(BError): code=27

def utc(): return dt.datetime.now(dt.timezone.utc).isoformat(timespec="milliseconds").replace("+00:00","Z")
def parse_utc(v): return dt.datetime.fromisoformat(v.replace("Z","+00:00"))
def canon(x): return (json.dumps(x,sort_keys=True,separators=(",",":"))+"\n").encode()
def sha_bytes(b): return hashlib.sha256(b).hexdigest()
def sha_file(p,chunk=1024*1024):
    h=hashlib.sha256()
    with open(p,"rb",buffering=0) as f:
        while True:
            b=f.read(chunk)
            if not b: break
            h.update(b)
    return h.hexdigest()
def valid_id(v,n):
    if not isinstance(v,str) or not ID_RE.fullmatch(v): raise Validation(f"invalid {n}")
    return v
def load_json(p):
    if p.is_symlink() or not p.is_file(): raise Validation(f"unsafe or missing JSON: {p}")
    try:return json.loads(p.read_text(encoding="utf-8"))
    except Exception as e: raise Validation(f"invalid JSON {p}: {e}")
def validate_doc(root,rel,doc):
    schema=load_json(root/rel)
    try: jsonschema.Draft202012Validator(schema,format_checker=jsonschema.FormatChecker()).validate(doc)
    except jsonschema.ValidationError as e: raise Validation(f"schema validation failed: {e.message}")
def policy(root):
    p=load_json(root/"config/backup_v2/policy-v1.1.0.json")
    validate_doc(root,"schemas/backup_v2/policy.schema.json",p)
    return p
def secret_env(ref):
    prefix="secret://env/"
    if not ref.startswith(prefix): raise Validation("unsupported secret reference")
    name=ref[len(prefix):]
    value=os.getenv(name)
    if not value: raise Validation(f"required secret unavailable: {name}")
    return value.encode()
def root_safe(root):
    if not root.is_absolute() or root.is_symlink(): raise Validation("unsafe framework root")
    cur=root
    while cur!=cur.parent:
        if cur.is_symlink(): raise Validation(f"symlink path component: {cur}")
        cur=cur.parent
    return root
def beneath(parent,child):
    rp=parent.resolve(strict=False); rc=child.resolve(strict=False)
    if rc!=rp and rp not in rc.parents: raise Validation(f"path escape: {child}")
    return rc
@contextlib.contextmanager
def lock(path,exclusive=True,blocking=False):
    path.parent.mkdir(parents=True,exist_ok=True,mode=0o750)
    fd=os.open(path,os.O_CREAT|os.O_RDWR|os.O_NOFOLLOW,0o640)
    try:
        mode=fcntl.LOCK_EX if exclusive else fcntl.LOCK_SH
        if not blocking: mode|=fcntl.LOCK_NB
        try: fcntl.flock(fd,mode)
        except BlockingIOError: raise Locked(f"lock busy: {path}")
        yield
    finally:
        try: fcntl.flock(fd,fcntl.LOCK_UN)
        finally: os.close(fd)
def atomic(path,data,mode=0o640):
    path.parent.mkdir(parents=True,exist_ok=True,mode=0o750)
    if path.is_symlink(): raise Validation(f"symlink refused: {path}")
    fd,tmp=tempfile.mkstemp(prefix=f".{path.name}.",dir=path.parent)
    try:
        os.fchmod(fd,mode)
        with os.fdopen(fd,"wb") as f: f.write(data); f.flush(); os.fsync(f.fileno())
        os.replace(tmp,path)
        dfd=os.open(path.parent,os.O_DIRECTORY)
        try: os.fsync(dfd)
        finally: os.close(dfd)
    finally:
        if os.path.exists(tmp): os.unlink(tmp)
def db(root):
    p=root/"state/backup_v2/backup.db"; p.parent.mkdir(parents=True,exist_ok=True,mode=0o750)
    c=sqlite3.connect(p,timeout=30,isolation_level=None)
    c.execute("PRAGMA journal_mode=WAL"); c.execute("PRAGMA synchronous=FULL"); c.execute("PRAGMA foreign_keys=ON"); c.execute("PRAGMA busy_timeout=30000")
    c.executescript("""
    CREATE TABLE IF NOT EXISTS backup_sets(
      backup_id TEXT PRIMARY KEY, component TEXT NOT NULL, name TEXT NOT NULL, classification TEXT NOT NULL,
      environment TEXT NOT NULL, status TEXT NOT NULL, manifest_path TEXT, manifest_sha256 TEXT,
      total_bytes INTEGER NOT NULL DEFAULT 0, file_count INTEGER NOT NULL DEFAULT 0,
      transaction_id TEXT, change_id TEXT NOT NULL, operator_id TEXT NOT NULL, reason TEXT NOT NULL,
      created_at TEXT NOT NULL, verified_at TEXT, retention_until TEXT NOT NULL, legal_hold INTEGER NOT NULL DEFAULT 0
    );
    CREATE TABLE IF NOT EXISTS blobs(
      blob_hash TEXT PRIMARY KEY, ciphertext_hash TEXT NOT NULL, size INTEGER NOT NULL,
      ref_count INTEGER NOT NULL, classification TEXT NOT NULL, encryption_provider TEXT,
      created_at TEXT NOT NULL, last_verified_at TEXT
    );
    CREATE TABLE IF NOT EXISTS backup_blob_refs(
      backup_id TEXT NOT NULL REFERENCES backup_sets(backup_id) ON DELETE CASCADE,
      blob_hash TEXT NOT NULL REFERENCES blobs(blob_hash), PRIMARY KEY(backup_id,blob_hash)
    );
    CREATE TABLE IF NOT EXISTS restore_plans(
      plan_id TEXT PRIMARY KEY, backup_id TEXT NOT NULL REFERENCES backup_sets(backup_id),
      component TEXT NOT NULL, target_class TEXT NOT NULL, target_root TEXT NOT NULL, mode TEXT NOT NULL,
      change_id TEXT NOT NULL, transaction_id TEXT, created_by TEXT NOT NULL, created_at TEXT NOT NULL,
      status TEXT NOT NULL, plan_path TEXT NOT NULL, plan_hash TEXT NOT NULL, required_approvals INTEGER NOT NULL,
      rehearsed_at TEXT, executed_at TEXT
    );
    CREATE TABLE IF NOT EXISTS approvals(
      approval_id TEXT PRIMARY KEY, plan_id TEXT NOT NULL REFERENCES restore_plans(plan_id),
      approver_id TEXT NOT NULL, token_hash TEXT NOT NULL, expires_at TEXT NOT NULL,
      used_at TEXT, created_at TEXT NOT NULL, UNIQUE(plan_id,approver_id)
    );
    CREATE TABLE IF NOT EXISTS exports(
      export_id TEXT PRIMARY KEY, backup_id TEXT NOT NULL REFERENCES backup_sets(backup_id),
      adapter TEXT NOT NULL, destination_identity TEXT NOT NULL, receipt_path TEXT NOT NULL,
      manifest_digest TEXT NOT NULL, retention_until TEXT NOT NULL, retention_mode TEXT NOT NULL,
      verified_at TEXT NOT NULL, authoritative INTEGER NOT NULL
    );
    CREATE TABLE IF NOT EXISTS event_head(id INTEGER PRIMARY KEY CHECK(id=1),last_sequence INTEGER NOT NULL,last_hash TEXT NOT NULL);
    INSERT OR IGNORE INTO event_head(id,last_sequence,last_hash) VALUES(1,0,printf('%064d',0));
    CREATE TABLE IF NOT EXISTS events(
      sequence INTEGER PRIMARY KEY, at_utc TEXT NOT NULL, kind TEXT NOT NULL, backup_id TEXT, plan_id TEXT,
      payload_json TEXT NOT NULL, previous_hash TEXT NOT NULL, event_hash TEXT NOT NULL,
      audit_event_id TEXT, execution_receipt_hash TEXT, transaction_event_hash TEXT, evidence_manifest_id TEXT
    );
    """)
    return c
def event(c,kind,backup_id=None,plan_id=None,payload=None,linkage=None):
    c.execute("BEGIN IMMEDIATE")
    try:
        seq,prev=c.execute("SELECT last_sequence,last_hash FROM event_head WHERE id=1").fetchone()
        seq+=1
        l0=linkage or {}
        l={"auditEventId":l0.get("auditEventId"),"executionReceiptHash":l0.get("executionReceiptHash"),
           "transactionEventHash":l0.get("transactionEventHash"),"evidenceManifestId":l0.get("evidenceManifestId")}
        body={"sequence":seq,"atUtc":utc(),"kind":kind,"backupId":backup_id,"planId":plan_id,
              "payload":payload or {},"previousHash":prev,"linkage":l}
        h=sha_bytes(canon(body))
        c.execute("""INSERT INTO events(sequence,at_utc,kind,backup_id,plan_id,payload_json,previous_hash,event_hash,
          audit_event_id,execution_receipt_hash,transaction_event_hash,evidence_manifest_id)
          VALUES(?,?,?,?,?,?,?,?,?,?,?,?)""",
          (seq,body["atUtc"],kind,backup_id,plan_id,json.dumps(body["payload"],sort_keys=True),prev,h,
           l.get("auditEventId"),l.get("executionReceiptHash"),l.get("transactionEventHash"),l.get("evidenceManifestId")))
        c.execute("UPDATE event_head SET last_sequence=?,last_hash=? WHERE id=1",(seq,h))
        c.execute("COMMIT"); return h
    except Exception:
        c.execute("ROLLBACK"); raise
def contract(pol,component):
    c=pol["componentContracts"].get(component)
    if not c: raise Validation(f"unknown component: {component}")
    return c
def approved(pol,component,p):
    rp=p.resolve(strict=False)
    for r in contract(pol,component)["roots"]:
        rr=Path(r).resolve(strict=False)
        if rp==rr or rr in rp.parents:return rr
    raise Validation(f"path not approved for {component}: {p}")
def transaction_check(root,pol,component,transaction_id,change_id):
    if pol["environment"]!="production": return
    if not transaction_id: raise TransactionRequired("transaction ID required in production")
    cli=root/pol["transactionIntegration"]["stateCli"]
    if not cli.is_file(): raise TransactionRequired("state engine unavailable")
    r=subprocess.run([str(cli),"tx-get",transaction_id],capture_output=True,text=True,timeout=10)
    if r.returncode: raise TransactionRequired("transaction not found")
    d=json.loads(r.stdout)
    if d.get("component")!=component or d.get("changeId")!=change_id or d.get("state")!=pol["transactionIntegration"]["requiredTransactionState"]:
        raise TransactionRequired("transaction mismatch or invalid state")
def require_gates(gates_json,required):
    supplied=set(json.loads(gates_json or "[]"))
    missing=[g for g in required if g not in supplied]
    if missing: raise Eligibility("missing required gates: "+",".join(missing))
def metadata(path,sensitive):
    st=os.stat(path,follow_symlinks=False)
    out={"mode":stat.S_IMODE(st.st_mode),"uid":st.st_uid,"gid":st.st_gid,"mtimeNs":st.st_mtime_ns,"ctimeNs":st.st_ctime_ns}
    xstatus="UNSUPPORTED"; x={}
    if hasattr(os,"listxattr"):
        try:
            for n in os.listxattr(path,follow_symlinks=False):
                x[n]=base64.b64encode(os.getxattr(path,n,follow_symlinks=False)).decode()
            xstatus="COMPLETE"
        except OSError:
            xstatus="FAILED"
    out["xattrs"]={"status":xstatus,"values":x}
    def cmd_capture(cmd):
        if not shutil.which(cmd[0]): return {"status":"UNSUPPORTED","value":None}
        r=subprocess.run(cmd,capture_output=True,text=True)
        return {"status":"COMPLETE" if r.returncode==0 else "FAILED","value":r.stdout if r.returncode==0 else None}
    out["acl"]=cmd_capture(["getfacl","-cp",str(path)])
    out["capabilities"]=cmd_capture(["getcap","-n",str(path)])
    if sensitive:
        for k in ("xattrs","acl","capabilities"):
            if out[k]["status"]=="FAILED": raise Integrity(f"required metadata capture failed: {k} {path}")
    return out
def copy_stream_stable(src,dst,chunk,max_file,encrypt_hook=None):
    before=os.stat(src,follow_symlinks=False)
    if not stat.S_ISREG(before.st_mode): raise Validation(f"not regular: {src}")
    if before.st_size>max_file: raise Validation(f"file exceeds limit: {src}")
    plain=hashlib.sha256()
    fd,tmp=tempfile.mkstemp(prefix=".capture.",dir=dst.parent)
    try:
        with os.fdopen(fd,"wb") as out, open(src,"rb",buffering=0) as inp:
            total=0
            while True:
                b=inp.read(chunk)
                if not b: break
                total+=len(b); plain.update(b); out.write(b)
            out.flush(); os.fsync(out.fileno())
        after=os.stat(src,follow_symlinks=False)
        attrs=("st_dev","st_ino","st_size","st_mtime_ns","st_ctime_ns")
        if any(getattr(before,a)!=getattr(after,a) for a in attrs): raise Conflict(f"source changed during capture: {src}")
        if encrypt_hook:
            enc_tmp=tmp+".enc"
            r=subprocess.run(encrypt_hook+[tmp,enc_tmp],capture_output=True,text=True,timeout=300)
            if r.returncode: raise Encryption("encryption hook failed")
            os.unlink(tmp); tmp=enc_tmp
        cipher_hash=sha_file(tmp)
        os.replace(tmp,dst)
        return plain.hexdigest(),cipher_hash,total
    finally:
        if os.path.exists(tmp): os.unlink(tmp)
def sign(pol,doc):
    key=secret_env(pol["manifestHmacSecretReference"])
    unsigned=dict(doc); unsigned.pop("authentication",None)
    return {"type":"HMAC-SHA256","keyReference":pol["manifestHmacSecretReference"],
            "value":hmac.new(key,canon(unsigned),hashlib.sha256).hexdigest()}
def verify_signature(pol,doc):
    auth=doc.get("authentication") or {}
    if auth.get("type")!="HMAC-SHA256": raise Integrity("HMAC authentication required")
    expected=sign(pol,doc)["value"]
    if not hmac.compare_digest(expected,auth.get("value","")): raise Integrity("manifest HMAC mismatch")
def ensure_space(root,pol,estimated=0):
    use=shutil.disk_usage(root)
    reserve=pol["storage"]["minimumFreeReserveBytes"]
    if use.free-estimated<reserve: raise Eligibility("insufficient free disk reserve")
def iter_tree(source,approved_root):
    source_dev=os.stat(approved_root,follow_symlinks=False).st_dev
    if source.is_symlink(): raise Validation(f"symlink refused: {source}")
    if source.is_file(): yield source; return
    for cur,dirs,files in os.walk(source,topdown=True,followlinks=False):
        cp=Path(cur)
        st=os.lstat(cp)
        if st.st_dev!=source_dev: raise Validation("filesystem boundary crossing")
        for n in list(dirs):
            p=cp/n
            if p.is_symlink(): raise Validation(f"symlink refused: {p}")
            if os.lstat(p).st_dev!=source_dev: raise Validation("filesystem boundary crossing")
        yield cp
        for n in files:
            p=cp/n
            st=os.lstat(p)
            if stat.S_ISLNK(st.st_mode) or not stat.S_ISREG(st.st_mode): raise Validation(f"unsupported file type: {p}")
            yield p
def create(root,args):
    pol=policy(root); valid_id(args.component,"component"); valid_id(args.name,"name")
    if args.classification not in pol["classifications"]: raise Validation("invalid classification")
    valid_id(args.change_id,"change ID"); valid_id(args.operator_id,"operator ID")
    transaction_check(root,pol,args.component,args.transaction_id,args.change_id)
    con=contract(pol,args.component); require_gates(args.gates_json,con["preBackupGates"])
    encrypt_required=args.classification in pol["encryption"]["requiredClassifications"]
    hook=pol["encryption"].get("hook")
    if encrypt_required and not hook: raise Encryption("required encryption provider is not configured")
    encrypt_hook=hook if isinstance(hook,list) else None
    linkage=json.loads(args.linkage_json or "{}")
    bid=str(uuid.uuid4()); component_lock=root/"state/locks/backup_v2"/f"component-{sha_bytes(args.component.encode())}.lock"
    with lock(root/"state/locks/backup_v2/global.lock"), lock(component_lock):
        c=db(root); now=utc(); until=(parse_utc(now)+dt.timedelta(days=pol["retention"]["defaultDays"])).isoformat().replace("+00:00","Z")
        c.execute("BEGIN IMMEDIATE")
        try:
            c.execute("""INSERT INTO backup_sets(backup_id,component,name,classification,environment,status,total_bytes,file_count,
              transaction_id,change_id,operator_id,reason,created_at,retention_until) VALUES(?,?,?,?,?,'ALLOCATED',0,0,?,?,?,?,?,?)""",
              (bid,args.component,args.name,args.classification,pol["environment"],args.transaction_id,args.change_id,args.operator_id,args.reason,now,until))
            c.execute("COMMIT")
        except Exception: c.execute("ROLLBACK"); raise
        stage=root/"backups_v2/staging"/bid; blobs_stage=stage/"blobs"; blobs_stage.mkdir(parents=True,mode=0o750)
        c.execute("UPDATE backup_sets SET status='CAPTURING' WHERE backup_id=?",(bid,))
        entries=[]; total=0; count=0; inode_map={}
        try:
            for raw in args.paths:
                src=Path(raw)
                ar=approved(pol,args.component,src)
                for p in iter_tree(src,ar):
                    count+=1
                    if count>pol["storage"]["maxFiles"]: raise Eligibility("file count limit exceeded")
                    st=os.lstat(p); rel=str(p)
                    sensitive=encrypt_required
                    meta=metadata(p,sensitive)
                    if stat.S_ISDIR(st.st_mode):
                        entries.append({"path":rel,"type":"directory",**meta}); continue
                    key=(st.st_dev,st.st_ino)
                    if key in inode_map:
                        entries.append({"path":rel,"type":"hardlink","linkTarget":inode_map[key],**meta}); continue
                    inode_map[key]=rel
                    tmp_dest=blobs_stage/f"tmp-{uuid.uuid4().hex}"
                    plain_hash,cipher_hash,size=copy_stream_stable(p,tmp_dest,pol["storage"]["chunkBytes"],pol["storage"]["maxFileBytes"],encrypt_hook)
                    total+=size
                    if total>pol["storage"]["maxBackupBytes"]: raise Eligibility("backup byte limit exceeded")
                    ensure_space(root,pol,total)
                    final_stage=blobs_stage/cipher_hash
                    if final_stage.exists(): tmp_dest.unlink()
                    else: os.replace(tmp_dest,final_stage)
                    entries.append({"path":rel,"type":"file","blobHash":plain_hash,"ciphertextHash":cipher_hash,
                                    "size":size,"encrypted":bool(encrypt_required),"encryptionProvider":pol["encryption"]["provider"] if encrypt_required else None,**meta})
            tree_hash=sha_bytes(canon(entries))
            manifest={"schemaVersion":"2.0","backupId":bid,"component":args.component,"name":args.name,
                      "classification":args.classification,"environment":pol["environment"],"transactionId":args.transaction_id,
                      "changeId":args.change_id,"operatorId":args.operator_id,"reason":args.reason,"createdAtUtc":now,
                      "status":"MANIFEST_STAGED","consistencyProvider":con["consistencyProvider"],"entries":entries,
                      "totalBytes":total,"fileCount":count,"treeHash":tree_hash,"authentication":{},
                      "linkage":linkage}
            manifest["authentication"]=sign(pol,manifest)
            validate_doc(root,"schemas/backup_v2/backup-manifest.schema.json",manifest)
            mpath=stage/"manifest.json"; atomic(mpath,json.dumps(manifest,indent=2).encode()+b"\n")
            verify_signature(pol,manifest)
            for e in entries:
                if e["type"]=="file":
                    sp=blobs_stage/e["ciphertextHash"]
                    if sha_file(sp)!=e["ciphertextHash"]: raise Integrity("staged blob verification failed")
            c.execute("UPDATE backup_sets SET status='VERIFYING' WHERE backup_id=?",(bid,))
            setdir=root/"backups_v2/sets"/bid; setdir.mkdir(parents=True,mode=0o750)
            prod_blobs=root/"backups_v2/blobs"; prod_blobs.mkdir(parents=True,exist_ok=True,mode=0o750)
            c.execute("BEGIN IMMEDIATE")
            try:
                for e in entries:
                    if e["type"]!="file": continue
                    srcblob=blobs_stage/e["ciphertextHash"]; dst=prod_blobs/e["ciphertextHash"]
                    if not dst.exists(): os.replace(srcblob,dst)
                    row=c.execute("SELECT ref_count FROM blobs WHERE blob_hash=?",(e["blobHash"],)).fetchone()
                    if row:c.execute("UPDATE blobs SET ref_count=ref_count+1,last_verified_at=? WHERE blob_hash=?",(utc(),e["blobHash"]))
                    else:c.execute("""INSERT INTO blobs(blob_hash,ciphertext_hash,size,ref_count,classification,encryption_provider,created_at,last_verified_at)
                      VALUES(?,?,?,?,?,?,?,?)""",(e["blobHash"],e["ciphertextHash"],e["size"],1,args.classification,e["encryptionProvider"],utc(),utc()))
                    c.execute("INSERT OR IGNORE INTO backup_blob_refs(backup_id,blob_hash) VALUES(?,?)",(bid,e["blobHash"]))
                final_manifest=setdir/"manifest.json"; os.replace(mpath,final_manifest)
                msha=sha_file(final_manifest)
                c.execute("""UPDATE backup_sets SET status='COMMITTED',manifest_path=?,manifest_sha256=?,total_bytes=?,file_count=?,verified_at=?
                  WHERE backup_id=?""",(str(final_manifest.relative_to(root)),msha,total,count,utc(),bid))
                c.execute("COMMIT")
            except Exception:c.execute("ROLLBACK"); raise
            event(c,"BACKUP_COMMITTED",bid,payload={"treeHash":tree_hash,"totalBytes":total,"fileCount":count},linkage=linkage)
            shutil.rmtree(stage,ignore_errors=True)
            return {"status":"COMMITTED","backupId":bid,"treeHash":tree_hash,"totalBytes":total,"fileCount":count}
        except Exception as e:
            c.execute("UPDATE backup_sets SET status='FAILED' WHERE backup_id=?",(bid,))
            event(c,"BACKUP_FAILED",bid,payload={"error":type(e).__name__})
            shutil.rmtree(stage,ignore_errors=True); raise
def verify(root,bid):
    pol=policy(root); valid_id(bid,"backup ID")
    with lock(root/"state/locks/backup_v2"/f"backup-{bid}.lock",exclusive=False):
        c=db(root); row=c.execute("SELECT manifest_path,manifest_sha256,status FROM backup_sets WHERE backup_id=?",(bid,)).fetchone()
        if not row: raise Validation("backup not found")
        mp=root/row[0]
        if sha_file(mp)!=row[1]: raise Integrity("manifest digest mismatch")
        m=load_json(mp); validate_doc(root,"schemas/backup_v2/backup-manifest.schema.json",m); verify_signature(pol,m)
        for e in m["entries"]:
            if e["type"]=="file":
                b=root/"backups_v2/blobs"/e["ciphertextHash"]
                if not b.is_file() or b.is_symlink() or sha_file(b)!=e["ciphertextHash"]: raise Integrity("blob verification failed")
        event(c,"BACKUP_VERIFIED",bid,payload={"treeHash":m["treeHash"]},linkage=m["linkage"])
        return {"status":"PASS","backupId":bid,"treeHash":m["treeHash"],"fileCount":m["fileCount"]}
def make_plan(root,args):
    pol=policy(root); valid_id(args.backup_id,"backup ID"); valid_id(args.change_id,"change ID"); valid_id(args.operator_id,"operator ID")
    if args.target_class not in pol["restore"]["targetClasses"] or args.mode not in pol["restore"]["modes"]: raise Validation("invalid restore policy")
    c=db(root); row=c.execute("SELECT component,manifest_path,status,transaction_id FROM backup_sets WHERE backup_id=?",(args.backup_id,)).fetchone()
    if not row or row[2]!="COMMITTED": raise Eligibility("backup is not committed")
    component=row[0]; m=load_json(root/row[1]); target=Path(args.target_root)
    if not target.is_absolute(): raise Validation("target root must be absolute")
    actions=[]
    expected=set()
    for e in m["entries"]:
        rel=Path(e["path"]).relative_to("/")
        dst=target/rel; expected.add(str(dst))
        action={"action":"ENSURE_DIRECTORY" if e["type"]=="directory" else "CREATE_HARDLINK" if e["type"]=="hardlink" else "CREATE_OR_REPLACE","target":str(dst),"entryType":e["type"]}
        actions.append(action)
    if args.mode=="EXACT" and target.exists():
        governed=[Path(x) for x in contract(pol,component)["roots"]]
        for gr in governed:
            mapped=target/gr.relative_to("/")
            if mapped.exists():
                for p in mapped.rglob("*"):
                    if str(p) not in expected: actions.append({"action":"DELETE_EXTRANEOUS","target":str(p),"entryType":"unknown"})
    required=pol["approval"]["minimumDistinctApprovers"] if args.target_class in pol["approval"]["requiredFor"] else 0
    plan={"schemaVersion":"2.0","planId":str(uuid.uuid4()),"backupId":args.backup_id,"component":component,
          "targetClass":args.target_class,"targetRoot":str(target),"mode":args.mode,"changeId":args.change_id,
          "transactionId":args.transaction_id or row[3],"createdBy":args.operator_id,"createdAtUtc":utc(),
          "status":"APPROVAL_PENDING" if required else "PLANNED","planHash":"","requiredApprovals":required,
          "actions":actions,"preValidationGates":contract(pol,component)["preRestoreGates"],
          "postValidationGates":contract(pol,component)["postRestoreGates"]}
    unsigned=dict(plan); unsigned["planHash"]=""; plan["planHash"]=sha_bytes(canon(unsigned))
    validate_doc(root,"schemas/backup_v2/restore-plan.schema.json",plan)
    p=root/"backups_v2/rehearsals"/f'{plan["planId"]}.plan.json'; atomic(p,json.dumps(plan,indent=2).encode()+b"\n")
    c.execute("""INSERT INTO restore_plans(plan_id,backup_id,component,target_class,target_root,mode,change_id,transaction_id,created_by,created_at,status,plan_path,plan_hash,required_approvals)
      VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?,?)""",(plan["planId"],args.backup_id,component,args.target_class,str(target),args.mode,args.change_id,plan["transactionId"],args.operator_id,plan["createdAtUtc"],plan["status"],str(p.relative_to(root)),plan["planHash"],required))
    event(c,"RESTORE_PLAN_CREATED",args.backup_id,plan["planId"],{"targetClass":args.target_class,"mode":args.mode})
    return {"planId":plan["planId"],"status":plan["status"],"approvalRequestId":plan["planId"],"planHash":plan["planHash"]}
def approve(root,args):
    pol=policy(root); valid_id(args.plan_id,"plan ID"); valid_id(args.approver_id,"approver ID")
    c=db(root); row=c.execute("SELECT plan_hash,created_by,status FROM restore_plans WHERE plan_id=?",(args.plan_id,)).fetchone()
    if not row: raise Validation("plan not found")
    if args.approver_id==row[1]: raise Approval("creator cannot approve own production restore")
    expires=parse_utc(utc())+dt.timedelta(minutes=pol["approval"]["ttlMinutes"])
    token_payload={"planId":args.plan_id,"planHash":row[0],"approverId":args.approver_id,"expiresAtUtc":expires.isoformat().replace("+00:00","Z"),"nonce":uuid.uuid4().hex}
    key=secret_env(pol["approval"]["signatureSecretReference"]); token=hmac.new(key,canon(token_payload),hashlib.sha256).hexdigest()
    aid=str(uuid.uuid4()); c.execute("INSERT INTO approvals(approval_id,plan_id,approver_id,token_hash,expires_at,created_at) VALUES(?,?,?,?,?,?)",
      (aid,args.plan_id,args.approver_id,sha_bytes(token.encode()),token_payload["expiresAtUtc"],utc()))
    event(c,"RESTORE_APPROVED",plan_id=args.plan_id,payload={"approvalId":aid,"approverId":args.approver_id})
    return {"approvalId":aid,"approvalToken":token,"expiresAtUtc":token_payload["expiresAtUtc"]}
def consume_approvals(root,pol,c,plan_id,tokens):
    row=c.execute("SELECT required_approvals FROM restore_plans WHERE plan_id=?",(plan_id,)).fetchone()
    required=row[0]; valid_count=0; used=[]
    for token in tokens:
        th=sha_bytes(token.encode())
        a=c.execute("SELECT approval_id,approver_id,expires_at,used_at FROM approvals WHERE plan_id=? AND token_hash=?",(plan_id,th)).fetchone()
        if not a or a[3] or parse_utc(a[2])<parse_utc(utc()): continue
        valid_count+=1; used.append(a[0])
    if valid_count<required: raise Approval("insufficient distinct valid approvals")
    for aid in used:c.execute("UPDATE approvals SET used_at=? WHERE approval_id=?",(utc(),aid))
def rehearse(root,args):
    pol=policy(root); c=db(root); row=c.execute("SELECT plan_path,backup_id,target_root,component FROM restore_plans WHERE plan_id=?",(args.plan_id,)).fetchone()
    if not row: raise Validation("plan not found")
    plan=load_json(root/row[0]); mrow=c.execute("SELECT manifest_path FROM backup_sets WHERE backup_id=?",(row[1],)).fetchone(); manifest=load_json(root/mrow[0])
    temp=Path(tempfile.mkdtemp(prefix="eif-restore-rehearsal-",dir=root/"backups_v2/rehearsals"))
    try:
        restore_tree(root,pol,manifest,temp,"MERGE",dry=False)
        verify_restored(manifest,temp)
        c.execute("UPDATE restore_plans SET status='REHEARSED',rehearsed_at=? WHERE plan_id=?",(utc(),args.plan_id))
        event(c,"RESTORE_REHEARSED",row[1],args.plan_id,{"target":str(temp)})
        return {"status":"PASS","planId":args.plan_id}
    finally: shutil.rmtree(temp,ignore_errors=True)
def restore_tree(root,pol,manifest,target_root,mode,dry=False):
    dirs=[]; files=[]; links=[]
    for e in manifest["entries"]:
        rel=Path(e["path"]).relative_to("/")
        dst=target_root/rel
        if e["type"]=="directory": dirs.append((dst,e))
        elif e["type"]=="file": files.append((dst,e))
        else: links.append((dst,e))
    for dst,e in dirs:
        if not dry: dst.mkdir(parents=True,exist_ok=True,mode=e["mode"])
    for dst,e in files:
        if dry: continue
        dst.parent.mkdir(parents=True,exist_ok=True)
        blob=root/"backups_v2/blobs"/e["ciphertextHash"]
        if e.get("encrypted"): raise Encryption("decryption hook required for encrypted restore")
        fd,tmp=tempfile.mkstemp(prefix=f".{dst.name}.restore.",dir=dst.parent)
        try:
            with os.fdopen(fd,"wb") as out, open(blob,"rb",buffering=0) as inp:
                shutil.copyfileobj(inp,out,1024*1024); out.flush(); os.fsync(out.fileno())
            os.chmod(tmp,e["mode"]); os.chown(tmp,e["uid"],e["gid"]); os.replace(tmp,dst)
            os.utime(dst,ns=(e["mtimeNs"],e["mtimeNs"]),follow_symlinks=False)
        finally:
            if os.path.exists(tmp): os.unlink(tmp)
    for dst,e in links:
        if dry: continue
        target=target_root/Path(e["linkTarget"]).relative_to("/")
        dst.parent.mkdir(parents=True,exist_ok=True)
        if dst.exists(): dst.unlink()
        os.link(target,dst)
        if os.stat(dst).st_ino!=os.stat(target).st_ino: raise Integrity("hardlink restore verification failed")
    for dst,e in sorted(dirs,key=lambda x:len(x[0].parts),reverse=True):
        if dry: continue
        os.chown(dst,e["uid"],e["gid"]); os.chmod(dst,e["mode"]); os.utime(dst,ns=(e["mtimeNs"],e["mtimeNs"]),follow_symlinks=False)
def verify_restored(manifest,target):
    h=[]
    for e in manifest["entries"]:
        dst=target/Path(e["path"]).relative_to("/")
        if e["type"]=="file":
            if sha_file(dst)!=e["blobHash"]: raise Integrity(f"restored digest mismatch: {dst}")
        elif e["type"]=="directory" and not dst.is_dir(): raise Integrity(f"directory missing: {dst}")
        h.append({"path":e["path"],"type":e["type"]})
    return sha_bytes(canon(h))
def restore(root,args):
    pol=policy(root); valid_id(args.plan_id,"plan ID"); c=db(root)
    row=c.execute("SELECT plan_path,backup_id,target_root,mode,status,component FROM restore_plans WHERE plan_id=?",(args.plan_id,)).fetchone()
    if not row: raise Validation("plan not found")
    plan=load_json(root/row[0]); validate_doc(root,"schemas/backup_v2/restore-plan.schema.json",plan)
    require_gates(args.pre_gates_json,plan["preValidationGates"])
    if pol["restore"]["requireRehearsal"] and row[4]!="REHEARSED": raise Eligibility("restore rehearsal required")
    tokens=json.loads(args.approval_tokens_json or "[]")
    with lock(root/"state/locks/backup_v2/global.lock"),lock(root/"state/locks/backup_v2"/f"restore-{args.plan_id}.lock"):
        c.execute("BEGIN IMMEDIATE")
        try: consume_approvals(root,pol,c,args.plan_id,tokens); c.execute("UPDATE restore_plans SET status='EXECUTING' WHERE plan_id=?",(args.plan_id,)); c.execute("COMMIT")
        except Exception:c.execute("ROLLBACK"); raise
        mpath=c.execute("SELECT manifest_path FROM backup_sets WHERE backup_id=?",(row[1],)).fetchone()[0]; manifest=load_json(root/mpath)
        target=Path(row[2]); restore_tree(root,pol,manifest,target,row[3],dry=False)
        tree=verify_restored(manifest,target); require_gates(args.post_gates_json,plan["postValidationGates"])
        c.execute("UPDATE restore_plans SET status='RESTORED',executed_at=? WHERE plan_id=?",(utc(),args.plan_id))
        event(c,"RESTORE_COMPLETED",row[1],args.plan_id,{"restoredTreeHash":tree})
        return {"status":"RESTORED","planId":args.plan_id,"restoredTreeHash":tree}
def export_authoritative(root,args):
    pol=policy(root); c=db(root); row=c.execute("SELECT manifest_path,manifest_sha256,classification FROM backup_sets WHERE backup_id=?",(args.backup_id,)).fetchone()
    if not row: raise Validation("backup not found")
    hook=pol["remoteExport"].get("hook")
    if not hook: raise RemoteExport("authoritative immutable export adapter not configured")
    receipt_file=root/"backups_v2/exports"/f"{args.backup_id}-{uuid.uuid4()}.receipt.json"
    r=subprocess.run(hook+[args.backup_id,str(root/row[0]),str(receipt_file)],capture_output=True,text=True,timeout=1800)
    if r.returncode: raise RemoteExport("immutable export hook failed")
    receipt=load_json(receipt_file)
    required=["destinationIdentity","objectIds","versionIds","retentionUntil","retentionMode","manifestDigest","blobCount","totalBytes","verifiedAtUtc","remoteAttestation"]
    if any(k not in receipt for k in required): raise RemoteExport("incomplete export receipt")
    if receipt["manifestDigest"]!=row[1]: raise RemoteExport("remote manifest digest mismatch")
    eid=str(uuid.uuid4()); c.execute("""INSERT INTO exports(export_id,backup_id,adapter,destination_identity,receipt_path,manifest_digest,retention_until,retention_mode,verified_at,authoritative)
      VALUES(?,?,?,?,?,?,?,?,?,1)""",(eid,args.backup_id,"external_immutable",receipt["destinationIdentity"],str(receipt_file.relative_to(root)),receipt["manifestDigest"],receipt["retentionUntil"],receipt["retentionMode"],receipt["verifiedAtUtc"]))
    event(c,"AUTHORITATIVE_EXPORT_VERIFIED",args.backup_id,payload={"exportId":eid,"destination":receipt["destinationIdentity"]})
    return {"status":"PASS","exportId":eid,"destinationIdentity":receipt["destinationIdentity"]}
def eligibility(root,args):
    pol=policy(root); c=db(root)
    b=c.execute("SELECT status,classification FROM backup_sets WHERE backup_id=?",(args.backup_id,)).fetchone()
    if not b: raise Validation("backup not found")
    exports=c.execute("SELECT COUNT(*) FROM exports WHERE backup_id=? AND authoritative=1",(args.backup_id,)).fetchone()[0]
    eligible=b[0]=="COMMITTED"
    reasons=[]
    if pol["remoteExport"]["requiredForAuthoritativeEvidence"] and b[1]=="forensic-evidence" and exports<pol["remoteExport"]["minimumAuthoritativeCopies"]:
        eligible=False; reasons.append("authoritative immutable export missing")
    return {"backupId":args.backup_id,"eligible":eligible,"authoritativeCopies":exports,"reasons":reasons}
def prune(root,args):
    pol=policy(root); c=db(root); now=parse_utc(utc())
    with lock(root/"state/locks/backup_v2/global.lock"),lock(root/"state/locks/backup_v2/prune.lock"):
        rows=c.execute("SELECT backup_id,retention_until,legal_hold FROM backup_sets ORDER BY created_at").fetchall()
        candidates=[]
        for bid,until,hold in rows:
            if hold: continue
            try: expired=parse_utc(until)<now
            except Exception: raise Validation("invalid retention timestamp")
            active=c.execute("SELECT COUNT(*) FROM restore_plans WHERE backup_id=? AND status IN ('APPROVAL_PENDING','APPROVED','EXECUTING')",(bid,)).fetchone()[0]
            if expired and not active:candidates.append(bid)
        if args.dry_run:return {"status":"DRY_RUN","candidates":candidates}
        for bid in candidates:
            refs=c.execute("SELECT blob_hash FROM backup_blob_refs WHERE backup_id=?",(bid,)).fetchall()
            c.execute("BEGIN IMMEDIATE")
            try:
                c.execute("DELETE FROM backup_sets WHERE backup_id=?",(bid,))
                for (bh,) in refs:
                    c.execute("UPDATE blobs SET ref_count=ref_count-1 WHERE blob_hash=?",(bh,))
                zero=c.execute("SELECT blob_hash,ciphertext_hash FROM blobs WHERE ref_count<=0").fetchall()
                for bh,ch in zero:
                    path=root/"backups_v2/blobs"/ch
                    if path.exists(): path.unlink()
                    c.execute("DELETE FROM blobs WHERE blob_hash=?",(bh,))
                c.execute("COMMIT")
            except Exception:c.execute("ROLLBACK"); raise
            shutil.rmtree(root/"backups_v2/sets"/bid,ignore_errors=True); event(c,"BACKUP_PRUNED",bid)
        return {"status":"PASS","pruned":candidates}
def reconcile(root,args):
    pol=policy(root); c=db(root); cutoff=parse_utc(utc())-dt.timedelta(minutes=pol["storage"]["stagingMaxAgeMinutes"])
    abandoned=[]
    for p in (root/"backups_v2/staging").iterdir():
        if not p.is_dir(): continue
        if dt.datetime.fromtimestamp(p.stat().st_mtime,dt.timezone.utc)<cutoff:
            abandoned.append(p.name)
            shutil.rmtree(p,ignore_errors=True)
            c.execute("UPDATE backup_sets SET status='FAILED' WHERE backup_id=? AND status!='COMMITTED'",(p.name,))
            event(c,"ABANDONED_STAGING_RECONCILED",p.name)
    return {"status":"PASS","abandoned":abandoned}
def verify_events(root,args):
    c=db(root); prev="0"*64; seq=0
    for row in c.execute("SELECT sequence,at_utc,kind,backup_id,plan_id,payload_json,previous_hash,event_hash,audit_event_id,execution_receipt_hash,transaction_event_hash,evidence_manifest_id FROM events ORDER BY sequence"):
        s,at,kind,bid,pid,payload,ph,eh,ae,er,te,em=row
        body={"sequence":s,"atUtc":at,"kind":kind,"backupId":bid,"planId":pid,"payload":json.loads(payload),"previousHash":ph,
              "linkage":{"auditEventId":ae,"executionReceiptHash":er,"transactionEventHash":te,"evidenceManifestId":em}}
        if s!=seq+1 or ph!=prev or sha_bytes(canon(body))!=eh: raise Integrity(f"event chain failure at {s}")
        seq=s; prev=eh
    head=c.execute("SELECT last_sequence,last_hash FROM event_head WHERE id=1").fetchone()
    if head!=(seq,prev): raise Integrity("event head mismatch")
    return {"status":"PASS","entries":seq,"lastHash":prev}
def main():
    a=argparse.ArgumentParser(); a.add_argument("--root",required=True,type=Path); s=a.add_subparsers(dest="cmd",required=True)
    p=s.add_parser("create"); p.add_argument("component"); p.add_argument("name"); p.add_argument("paths",nargs="+"); p.add_argument("--classification",default="configuration"); p.add_argument("--transaction-id"); p.add_argument("--change-id",required=True); p.add_argument("--operator-id",required=True); p.add_argument("--reason",required=True); p.add_argument("--gates-json",default="[]"); p.add_argument("--linkage-json",default="{}")
    p=s.add_parser("verify"); p.add_argument("backup_id")
    p=s.add_parser("plan"); p.add_argument("backup_id"); p.add_argument("target_root"); p.add_argument("--target-class",required=True); p.add_argument("--mode",required=True); p.add_argument("--change-id",required=True); p.add_argument("--operator-id",required=True); p.add_argument("--transaction-id")
    p=s.add_parser("approve"); p.add_argument("plan_id"); p.add_argument("--approver-id",required=True)
    p=s.add_parser("rehearse"); p.add_argument("plan_id")
    p=s.add_parser("restore"); p.add_argument("plan_id"); p.add_argument("--approval-tokens-json",default="[]"); p.add_argument("--pre-gates-json",default="[]"); p.add_argument("--post-gates-json",default="[]")
    p=s.add_parser("export-authoritative"); p.add_argument("backup_id")
    p=s.add_parser("eligibility"); p.add_argument("backup_id")
    p=s.add_parser("prune"); p.add_argument("--dry-run",action="store_true")
    s.add_parser("reconcile"); s.add_parser("verify-events")
    x=a.parse_args(); root=root_safe(x.root)
    try:
        if x.cmd=="create": out=create(root,x)
        elif x.cmd=="verify": out=verify(root,x.backup_id)
        elif x.cmd=="plan": out=make_plan(root,x)
        elif x.cmd=="approve": out=approve(root,x)
        elif x.cmd=="rehearse": out=rehearse(root,x)
        elif x.cmd=="restore": out=restore(root,x)
        elif x.cmd=="export-authoritative": out=export_authoritative(root,x)
        elif x.cmd=="eligibility": out=eligibility(root,x)
        elif x.cmd=="prune": out=prune(root,x)
        elif x.cmd=="reconcile": out=reconcile(root,x)
        else: out=verify_events(root,x)
        print(json.dumps(out,indent=2,sort_keys=True))
    except BError as e:
        print(json.dumps({"status":"ERROR","error":type(e).__name__,"message":str(e)}),file=sys.stderr); raise SystemExit(e.code)
if __name__=="__main__": main()
