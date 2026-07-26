#!/usr/bin/env bash
set -Eeuo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)"; export EIF_ROOT="$ROOT" EIF_ENVIRONMENT=test; source "$ROOT/framework/core/framework.sh"
f=0; a(){ [[ "$1" == "$2" ]] && echo "PASS: $3" || { echo "FAIL: $3 expected=$1 actual=$2"; f=$((f+1)); }; }
a test "$(eif_config_get deployment.environment)" environment; a true "$(eif_config_get framework.failClosed false)" fail_closed; a false "$(eif_config_get safety.allowServiceRestart true)" no_restart
eif_version_compare 1.2.0 ge 1.1.9 || f=$((f+1)); [[ -n "$EIF_RUN_ID" && -s "$EIF_RESOLVED_CONFIG" ]] || f=$((f+1)); ((f==0))
