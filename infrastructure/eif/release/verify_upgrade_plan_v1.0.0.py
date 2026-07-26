#!/usr/bin/env python3
import hashlib,json,sys
from pathlib import Path
p,b=Path(sys.argv[1]),Path(sys.argv[2]);raw=p.read_bytes();expected=(b/'plan.sha256').read_text().strip()
if hashlib.sha256(raw).hexdigest()!=expected:raise SystemExit('plan hash mismatch')
d=json.loads(raw)
for e in d['files']:
 rel=Path(e['path'])
 if rel.is_absolute() or '..' in rel.parts:raise SystemExit('unsafe plan path')
 if e['action']=='REPLACE':
  blob=b/'files'/e['backupBlob']
  if not blob.is_file() or hashlib.sha256(blob.read_bytes()).hexdigest()!=e['oldSha256']:raise SystemExit('backup blob mismatch')
print('PASS: upgrade plan verified')
