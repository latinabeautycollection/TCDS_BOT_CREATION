#!/usr/bin/env bash
set -Eeuo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)"
for i in $(seq 1 10); do "$ROOT/bin/eif-validate-v3" status >/dev/null & done
wait
echo PASS
