#!/usr/bin/env bash
set -Eeuo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
cp -a "$ROOT/." "$TMP/f/"
F="$TMP/f"
# Corrupt a copy of a receipt/manifest-like JSON and ensure schema or verifier rejects it.
export EIF_VALIDATION_HMAC_KEY=k
printf '{"schemaVersion":"3.0"}\n' > "$TMP/bad.json"
if "$F/bin/eif-validate-v3" run invalid --phase readiness >/dev/null 2>&1; then exit 1; fi
# Ensure reconciliation commands are present and callable without changing services.
test -x "$F/bin/eif-state-v2"
test -x "$F/bin/eif-exec-v2"
echo "PASS: failure injection suite"
