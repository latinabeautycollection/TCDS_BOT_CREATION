#!/usr/bin/env bash
set -Eeuo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)"
# Verify unsafe identifiers are rejected by validation v3.
export EIF_VALIDATION_HMAC_KEY=k
if "$ROOT/bin/eif-validate-v3" run ../../bad --phase preflight >/dev/null 2>&1; then exit 1; fi
# Verify production backup rejects missing HMAC.
unset EIF_BACKUP_HMAC_KEY
if "$ROOT/bin/eif-backup-v2" verify not-a-valid-backup >/dev/null 2>&1; then exit 1; fi
echo "PASS: security negative suite"
