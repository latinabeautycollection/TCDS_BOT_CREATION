#!/usr/bin/env bash
set -Eeuo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
cp -a "$ROOT/." "$TMP/f/"
F="$TMP/f"; export EIF_VALIDATION_HMAC_KEY=testkey
python3 - "$F/config/validation_v3/policy-v1.3.0.json" <<'PY'
import json,sys
p=sys.argv[1];d=json.load(open(p));d["environment"]="test";d["auditRequired"]=False
d["components"]["test"]={"phases":{"preflight":["test_http"],"evidence_seal":["test_evidence"]}}
json.dump(d,open(p,"w"),indent=2)
PY
cat > "$F/validators_v3/contracts/test_http.json" <<'JSON'
{"schemaVersion":"3.0","checkId":"test_http","component":"test","version":"1.0.0","phases":["preflight"],"mode":"composite","description":"Test probe","failureClass":"DEPENDENCY","severityOnFailure":"CRITICAL","requiredPrivileges":"unprivileged","sideEffects":"none","execution":null,"criteria":{"probe":"test_probe"},"redaction":{"enabled":true,"piiMode":"mask"}}
JSON
mkdir -p "$F/health_v3/state/probes"; echo '{"status":"PASS"}' > "$F/health_v3/state/probes/test_probe.json"
out="$("$F/bin/eif-validate-v3" run test --phase preflight --context-json '{"runId":"run-001"}')"
grep -q '"status": "PASS"' <<<"$out"
# Mandatory subset bypass rejected.
if "$F/bin/eif-validate-v3" run test --phase preflight --checks wrong --context-json '{"runId":"run-002"}' >/dev/null 2>&1; then exit 1; fi
"$F/bin/eif-validate-v3" status >/dev/null
"$F/bin/eif-validate-v3" metrics >/dev/null
test -s "$F/health_v3/metrics/validation.prom"
echo 'PASS: Milestone 1B.7 Green Tier 1 v1.3.0'
