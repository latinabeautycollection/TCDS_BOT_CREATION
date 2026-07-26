#!/usr/bin/env bash
set -Eeuo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)"
for x in eif-log-v2 eif-exec-v2 eif-state-v2 eif-backup-v2 eif-validate-v3; do
  test -x "$ROOT/bin/$x"
done
test -f "$ROOT/config/validation_v3/policy-v1.3.0.json"
test -f "$ROOT/config/backup_v2/policy-v1.1.0.json"
echo "PASS: integration suite"
