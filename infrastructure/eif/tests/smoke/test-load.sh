#!/usr/bin/env bash
set -Eeuo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)"; export EIF_ROOT="$ROOT" EIF_ENVIRONMENT=production; source "$ROOT/framework/core/framework.sh"; python3 -m json.tool "$EIF_RESOLVED_CONFIG" >/dev/null; "$ROOT/bin/eif-info" >/dev/null; echo 'PASS: framework smoke test'
