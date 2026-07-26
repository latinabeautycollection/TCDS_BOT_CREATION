#!/usr/bin/env python3
from __future__ import annotations
import argparse, copy, hashlib, json, os, re, socket, sys, tempfile
from pathlib import Path
from typing import Any

SECRET_RE=re.compile(r"^secret://(env|file)/(.+)$")
class ConfigError(Exception): pass

def load(path:Path, required=False):
    if not path.exists():
        if required: raise ConfigError(f"missing JSON: {path}")
        return {}
    if path.is_symlink(): raise ConfigError(f"symlink refused: {path}")
    try: return json.loads(path.read_text())
    except json.JSONDecodeError as e: raise ConfigError(f"invalid JSON {path}: {e}")

def merge(a,b):
    if isinstance(a,dict) and isinstance(b,dict):
        c=copy.deepcopy(a)
        for k,v in b.items(): c[k]=merge(c[k],v) if k in c else copy.deepcopy(v)
        return c
    return copy.deepcopy(b)

def canon(x): return (json.dumps(x,sort_keys=True,separators=(',',':'))+'\n').encode()
def digest(b): return hashlib.sha256(b).hexdigest()
def atomic(path:Path,data:bytes,mode=0o600):
    path.parent.mkdir(parents=True,exist_ok=True,mode=0o750)
    if path.is_symlink(): raise ConfigError(f"output symlink refused: {path}")
    fd,tmp=tempfile.mkstemp(prefix='.'+path.name+'.',dir=path.parent)
    try:
        os.fchmod(fd,mode)
        with os.fdopen(fd,'wb') as f: f.write(data); f.flush(); os.fsync(f.fileno())
        os.replace(tmp,path)
    finally:
        if os.path.exists(tmp): os.unlink(tmp)

def validate(value,schema,path='$'):
    errors=[]; t=schema.get('type'); types=t if isinstance(t,list) else ([t] if t else [])
    chk={'object':lambda v:isinstance(v,dict),'array':lambda v:isinstance(v,list),'string':lambda v:isinstance(v,str),'integer':lambda v:isinstance(v,int) and not isinstance(v,bool),'number':lambda v:isinstance(v,(int,float)) and not isinstance(v,bool),'boolean':lambda v:isinstance(v,bool),'null':lambda v:v is None}
    if types and not any(chk.get(x,lambda _:False)(value) for x in types): return [f"{path}: wrong type"]
    if 'enum' in schema and value not in schema['enum']: errors.append(f"{path}: invalid enum")
    if isinstance(value,dict):
        for req in schema.get('required',[]):
            if req not in value: errors.append(f"{path}: missing {req}")
        props=schema.get('properties',{})
        for k,v in value.items():
            if k in props: errors+=validate(v,props[k],path+'.'+k)
            elif schema.get('additionalProperties') is False: errors.append(f"{path}: unknown {k}")
            elif isinstance(schema.get('additionalProperties'),dict): errors+=validate(v,schema['additionalProperties'],path+'.'+k)
    if isinstance(value,list):
        if schema.get('uniqueItems') and len({json.dumps(x,sort_keys=True) for x in value})!=len(value): errors.append(f"{path}: duplicates")
        if 'items' in schema:
            for i,v in enumerate(value): errors+=validate(v,schema['items'],f"{path}[{i}]")
    if isinstance(value,str):
        if len(value)<schema.get('minLength',0): errors.append(f"{path}: too short")
        if 'pattern' in schema and not re.search(schema['pattern'],value): errors.append(f"{path}: pattern")
    if isinstance(value,(int,float)) and not isinstance(value,bool):
        if 'minimum' in schema and value<schema['minimum']: errors.append(f"{path}: below minimum")
        if 'maximum' in schema and value>schema['maximum']: errors.append(f"{path}: above maximum")
    return errors

def secret_errors(v,verify=False,path='$'):
    e=[]
    if isinstance(v,dict):
        for k,x in v.items(): e+=secret_errors(x,verify,path+'.'+k)
    elif isinstance(v,list):
        for i,x in enumerate(v): e+=secret_errors(x,verify,f"{path}[{i}]")
    elif isinstance(v,str) and v.startswith('secret://'):
        m=SECRET_RE.match(v)
        if not m: e.append(f"{path}: invalid secret reference")
        else:
            kind,target=m.groups()
            if kind=='env' and verify and target not in os.environ: e.append(f"{path}: missing env secret")
            if kind=='file':
                p=Path(target)
                if not p.is_absolute(): e.append(f"{path}: secret file must be absolute")
                elif verify and (not p.is_file() or p.is_symlink() or (p.stat().st_mode & 0o077)): e.append(f"{path}: unsafe secret file")
    return e

def resolve(args):
    root=Path(args.root).resolve(); host=args.hostname or socket.gethostname().split('.')[0]
    layers=[root/'config/defaults/framework.json',root/f'config/environments/{args.environment}.json',root/f'config/hosts/{host}.json']
    if args.component: layers.append(root/f'config/components/{args.component}.json')
    if args.runtime: layers.append(Path(args.runtime).resolve())
    data={}; used=[]
    for p in layers:
        if p.exists(): data=merge(data,load(p,True)); used.append(str(p))
    errors=validate(data,load(root/'schemas/framework-config.schema.json',True))+secret_errors(data,args.verify_secrets)
    if errors: raise ConfigError('; '.join(errors))
    body=canon(data); atomic(Path(args.output),body)
    meta={'status':'PASS','layers':used,'sha256':digest(body),'output':args.output}
    atomic(Path(args.output+'.meta.json'),(json.dumps(meta,indent=2)+'\n').encode())
    print(json.dumps(meta,indent=2))

def validate_cmd(args):
    data=load(Path(args.input),True); errors=validate(data,load(Path(args.schema),True))+secret_errors(data,args.verify_secrets)
    if errors: raise ConfigError('; '.join(errors))
    print(json.dumps({'status':'PASS','input':args.input},indent=2))

def render(args):
    cur=load(Path(args.input),True)
    for part in args.key.split('.'):
        if not isinstance(cur,dict) or part not in cur: raise ConfigError('missing render key')
        cur=cur[part]
    if not isinstance(cur,str): raise ConfigError('render key not string')
    out=Path(args.output); data=cur.encode()
    if out.exists() and not args.replace:
        if out.read_bytes()==data: print('{"status":"UNCHANGED"}'); return
        raise ConfigError('immutable render collision')
    atomic(out,data,int(args.mode,8)); print(json.dumps({'status':'RENDERED','sha256':digest(data)},indent=2))

def snapshot(args):
    files=[]
    for raw in args.paths:
        p=Path(raw)
        if p.is_symlink(): raise ConfigError('snapshot symlink refused')
        if p.is_file(): files.append(p)
        elif p.is_dir(): files += [x for x in p.rglob('*') if x.is_file() and not x.is_symlink()]
    records=[{'path':str(p.resolve()),'sha256':digest(p.read_bytes()),'mode':oct(p.stat().st_mode&0o777)} for p in sorted(set(files),key=str)]
    atomic(Path(args.output),(json.dumps({'records':records},indent=2)+'\n').encode())
    print(json.dumps({'status':'SNAPSHOT_CREATED','count':len(records)},indent=2))

def drift(args):
    d=[]
    for r in load(Path(args.snapshot),True).get('records',[]):
        p=Path(r['path'])
        if not p.exists(): d.append({'path':str(p),'status':'MISSING'}); continue
        if p.is_symlink(): d.append({'path':str(p),'status':'SYMLINK'}); continue
        if digest(p.read_bytes())!=r['sha256']: d.append({'path':str(p),'status':'MODIFIED'})
        if oct(p.stat().st_mode&0o777)!=r['mode']: d.append({'path':str(p),'status':'MODE_CHANGED'})
    print(json.dumps({'status':'DRIFT' if d else 'PASS','drift':d},indent=2)); return 10 if d else 0

def main():
    p=argparse.ArgumentParser(); s=p.add_subparsers(dest='cmd',required=True)
    x=s.add_parser('resolve'); x.add_argument('--root',required=True); x.add_argument('--environment',required=True); x.add_argument('--hostname'); x.add_argument('--component'); x.add_argument('--runtime'); x.add_argument('--output',required=True); x.add_argument('--verify-secrets',action='store_true'); x.set_defaults(fn=resolve)
    x=s.add_parser('validate'); x.add_argument('--input',required=True); x.add_argument('--schema',required=True); x.add_argument('--verify-secrets',action='store_true'); x.set_defaults(fn=validate_cmd)
    x=s.add_parser('render'); x.add_argument('--input',required=True); x.add_argument('--key',required=True); x.add_argument('--output',required=True); x.add_argument('--mode',default='0640'); x.add_argument('--replace',action='store_true'); x.set_defaults(fn=render)
    x=s.add_parser('snapshot'); x.add_argument('--output',required=True); x.add_argument('paths',nargs='+'); x.set_defaults(fn=snapshot)
    x=s.add_parser('drift'); x.add_argument('--snapshot',required=True); x.set_defaults(fn=drift)
    a=p.parse_args()
    try: return a.fn(a) or 0
    except ConfigError as e: print('CONFIG-ERROR:',e,file=sys.stderr); return 6
if __name__=='__main__': raise SystemExit(main())
