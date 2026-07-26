#!/usr/bin/env bash
set -Eeuo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
cp -a "$ROOT/." "$TMP/f/"
F="$TMP/f"
unset EIF_VALIDATION_HMAC_KEY
if "$F/bin/eif-validate" run clock --checks clock_synchronized >/dev/null 2>&1; then exit 1; fi
export EIF_VALIDATION_HMAC_KEY=k
# Unknown component must fail.
if "$F/bin/eif-validate" run ../../bad >/dev/null 2>&1; then exit 1; fi
# Corrupt contract must fail schema validation.
printf '{"bad":true}\n' > "$F/validators/contracts/clock_synchronized.json"
if "$F/bin/eif-validate" run clock --checks clock_synchronized >/dev/null 2>&1; then exit 1; fi
echo 'PASS: validation negative controls'
