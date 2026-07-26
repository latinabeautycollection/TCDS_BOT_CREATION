#!/usr/bin/env bash
eif_version_compare() {
  python3 - "$1" "$2" "$3" <<'PYV'
import sys
a,op,b=sys.argv[1:]
def n(v): return tuple(int(''.join(c for c in p if c.isdigit()) or 0) for p in v.split('.'))
aa,bb=n(a),n(b); c=(aa>bb)-(aa<bb)
ok={'eq':c==0,'ne':c!=0,'gt':c>0,'ge':c>=0,'lt':c<0,'le':c<=0}.get(op,False)
raise SystemExit(0 if ok else 1)
PYV
}
eif_require_framework_version(){ eif_version_compare "$EIF_VERSION" ge "$1"; }
