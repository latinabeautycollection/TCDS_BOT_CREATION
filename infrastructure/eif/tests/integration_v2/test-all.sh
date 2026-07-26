#!/usr/bin/env bash
set -Eeuo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)"
for x in eif-log-v2 eif-exec-v2 eif-state-v2 eif-backup-v2 eif-validate-v3 eif-certify-v2; do test -x "$ROOT/bin/$x"; done
echo PASS
