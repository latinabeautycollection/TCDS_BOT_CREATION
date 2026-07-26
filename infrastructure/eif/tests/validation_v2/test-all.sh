#!/usr/bin/env bash
set -Eeuo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
cp -a "$ROOT/." "$TMP/f/"
F="$TMP/f"; export EIF_VALIDATION_HMAC_KEY=test-validation-key
# Test-only component and contracts.
python3 - "$F/config/validation/policy-v1.2.0.json" <<'PY'
import json,sys
p=sys.argv[1];d=json.load(open(p));d["environment"]="test";d["components"]["test"]={"requiredChecks":["test_pass","test_evidence"],"commitChecks":[]};json.dump(d,open(p,"w"),indent=2)
PY
cat > "$F/validators/contracts/test_pass.json" <<'JSON'
{"schemaVersion":"1.0","checkId":"test_pass","component":"test","version":"1.0.0","description":"Harmless true command","mode":"command","timeoutSeconds":5,"failureClass":"DEPENDENCY","severityOnFailure":"CRITICAL","command":"/usr/bin/true","arguments":[],"environment":{},"successCriteria":{"exitCodes":[0]},"redaction":{"enabled":true},"requiredPrivileges":"unprivileged","sideEffects":"none"}
JSON
cat > "$F/validators/contracts/test_evidence.json" <<'JSON'
{"schemaVersion":"1.0","checkId":"test_evidence","component":"test","version":"1.0.0","description":"Evidence completeness test","mode":"evidence","timeoutSeconds":5,"failureClass":"EVIDENCE_COMPLETENESS","severityOnFailure":"CRITICAL","command":null,"arguments":[],"environment":{},"successCriteria":{"policyRef":"evidenceCompleteness"},"redaction":{"enabled":true},"requiredPrivileges":"unprivileged","sideEffects":"none"}
JSON
evidence='{"receivedSources":["browser_snapshot","fingerprintjs","creepjs","envoy_edge","suricata_network","behavior_summary","challenge","transaction","final_score","evidence_manifest"],"correlationConfidence":0.99,"clockSkewSeconds":0.2}'
out="$("$F/bin/eif-validate" run test --evidence-json "$evidence")"
grep -q '"status": "PASS"' <<<"$out"
receipt="$(find "$F/health/reports/test" -type f -name '*.json' ! -name 'run-*' | head -1)"
"$F/bin/eif-validate" verify-receipt "$receipt" >/dev/null
"$F/bin/eif-validate" status >/dev/null
test -s "$F/health/metrics/validation.prom"
# Incomplete evidence must fail the run.
bad="$("$F/bin/eif-validate" run test --evidence-json '{"receivedSources":[],"correlationConfidence":0,"clockSkewSeconds":9}')"
grep -q '"status": "FAIL"' <<<"$bad"
echo 'PASS: Milestone 1B.7 validation and health framework'
