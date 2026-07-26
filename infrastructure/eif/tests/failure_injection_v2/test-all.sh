#!/usr/bin/env bash
set -Eeuo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)"
unset EIF_VALIDATION_HMAC_KEY
if "$ROOT/bin/eif-validate-v3" run clock --phase preflight >/dev/null 2>&1; then exit 1; fi
echo PASS
