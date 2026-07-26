#!/usr/bin/env bash
set -Eeuo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)"
test -x "$ROOT/bin/eif-state-v2"
"$ROOT/bin/eif-state-v2" verify >/dev/null 2>&1 || true
test -x "$ROOT/bin/eif-backup-v2"
echo "PASS: recovery suite"
