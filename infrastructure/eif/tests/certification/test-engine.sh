#!/usr/bin/env bash
set -Eeuo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
cp -a "$ROOT/." "$TMP/f/"
F="$TMP/f"
export EIF_CERTIFICATION_HMAC_KEY=cert-key EIF_VALIDATION_HMAC_KEY=val-key EIF_BACKUP_HMAC_KEY=backup-key EIF_APPROVAL_HMAC_KEY=approval-key
# Run only focused suites that do not require real Envoy/Suricata/PQP services.
out="$("$F/bin/eif-certify" run --suites security_negative concurrency failure_injection recovery integration --timeout 60)"
grep -Eq '"grade": "(AMBER|GREEN_TIER_1)"' <<<"$out"
report="$(find "$F/certification/reports" -type f -name '*.json' ! -name latest.json | head -1)"
"$F/bin/eif-certify" verify "$report" >/dev/null
echo "PASS: Milestone 1B.8 certification engine"
