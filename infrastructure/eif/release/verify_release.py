#!/usr/bin/env python3
import hashlib,json,sys
from pathlib import Path
root=Path(sys.argv[1]);m=json.loads((root/"release/manifest.json").read_text())
for rel,expected in m["files"].items():
 p=root/rel
 if not p.is_file() or hashlib.sha256(p.read_bytes()).hexdigest()!=expected:raise SystemExit(f"release verification failed: {rel}")
print("release manifest verified")
