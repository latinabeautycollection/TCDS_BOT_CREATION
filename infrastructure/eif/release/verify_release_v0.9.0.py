#!/usr/bin/env python3
import hashlib,json,sys
from pathlib import Path
r=Path(sys.argv[1]); m=json.loads((r/'release/manifest-v0.9.0.json').read_text())
for e in m['files']:
 p=r/e['path']
 if not p.is_file() or p.is_symlink() or hashlib.sha256(p.read_bytes()).hexdigest()!=e['sha256']: raise SystemExit('release verification failed: '+e['path'])
print('PASS: release verified')
