#!/usr/bin/env bash
set -Eeuo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)"
TMP="$(mktemp -d)";trap 'rm -rf "$TMP"' EXIT
cp -a "$ROOT/." "$TMP/f/"
F="$TMP/f";export EIF_CERTIFICATION_HMAC_KEY=cert EIF_VALIDATION_HMAC_KEY=val EIF_BACKUP_HMAC_KEY=back EIF_APPROVAL_HMAC_KEY=approve
out="$("$F/bin/eif-certify-v2" run --mode UNIT_TEST --suites security_negative framework_concurrency failure_injection recovery cross_milestone_integration --timeout 60)"
grep -q '"grade": "AMBER"' <<<"$out"
grep -q '"certifyingRun": false' <<<"$out"
report="$(find "$F/certification_v2/reports" -name '*.json' ! -name latest.json | head -1)"
"$F/bin/eif-certify-v2" verify "$report" >/dev/null
echo PASS
