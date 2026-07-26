#!/usr/bin/env bash
set -Eeuo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)"
"$ROOT/bin/eif-state-v2" verify >/dev/null
"$ROOT/bin/eif-exec-v2" reconcile >/dev/null
"$ROOT/bin/eif-backup-v2" reconcile >/dev/null
echo PASS
