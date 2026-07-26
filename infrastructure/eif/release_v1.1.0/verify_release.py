#!/usr/bin/env python3
import hashlib,json,os,subprocess,sys
from pathlib import Path
root=Path(sys.argv[1]).resolve()
m=json.loads((root/"release_v1.1.0/release-manifest.json").read_text())
for e in m["files"]:
    p=root/e["path"]
    if not p.is_file() or p.is_symlink(): raise SystemExit(f"missing/unsafe release file: {e['path']}")
    if hashlib.sha256(p.read_bytes()).hexdigest()!=e["sha256"]: raise SystemExit(f"hash mismatch: {e['path']}")
pub=root/"release_v1.1.0/release-public.pem"
fp=hashlib.sha256(pub.read_bytes()).hexdigest()
expected=os.getenv("EIF_TRUSTED_RELEASE_KEY_SHA256")
if not expected or expected!=fp: raise SystemExit("trusted release-key fingerprint missing or mismatched")
r=subprocess.run(["openssl","pkeyutl","-verify","-pubin","-inkey",str(pub),"-rawin",
                  "-in",str(root/"release_v1.1.0/release-manifest.json"),
                  "-sigfile",str(root/"release_v1.1.0/release-manifest.sig")])
if r.returncode: raise SystemExit("release signature invalid")
print(json.dumps({"status":"PASS","publicKeySha256":fp}))
