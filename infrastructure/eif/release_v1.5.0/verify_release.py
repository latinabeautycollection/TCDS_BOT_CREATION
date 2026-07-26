#!/usr/bin/env python3
import hashlib,json,os,subprocess,sys
from pathlib import Path
r=Path(sys.argv[1]);m=json.loads((r/'release_v1.5.0/release-manifest.json').read_text())
for e in m['files']:
 p=r/e['path']
 if hashlib.sha256(p.read_bytes()).hexdigest()!=e['sha256']:raise SystemExit(1)
pub=r/'release_v1.5.0/release-public.pem';exp=os.getenv('EIF_TRUSTED_RELEASE_KEY_SHA256')
if not exp or hashlib.sha256(pub.read_bytes()).hexdigest()!=exp:raise SystemExit(1)
raise SystemExit(subprocess.run(['openssl','pkeyutl','-verify','-pubin','-inkey',str(pub),'-rawin','-in',str(r/'release_v1.5.0/release-manifest.json'),'-sigfile',str(r/'release_v1.5.0/release-manifest.sig')]).returncode)
