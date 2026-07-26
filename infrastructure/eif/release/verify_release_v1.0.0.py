#!/usr/bin/env python3
import hashlib,json,sys
from pathlib import Path
r=Path(sys.argv[1]);m=json.loads((r/'release/manifest-v1.0.0.json').read_text())
for e in m['files']:
 p=r/e['path']
 if p.is_symlink() or not p.is_file() or hashlib.sha256(p.read_bytes()).hexdigest()!=e['sha256']:raise SystemExit('release verification failed: '+e['path'])
print('PASS: release verified')
