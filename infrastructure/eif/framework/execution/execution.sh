#!/usr/bin/env bash
# shellcheck shell=bash
framework::__execution_engine() { printf '%s/framework/execution/execution_engine.py' "$EIF_ROOT"; }
framework::execution::run() { "$(framework::__execution_engine)" --root "$EIF_ROOT" run; }
framework::execution::validate() { "$(framework::__execution_engine)" --root "$EIF_ROOT" validate; }
framework::execution::request() {
  local command="$1" operation="$2" component="${3:-framework}"; shift 3 || true
  python3 - "$command" "$operation" "$component" "$@" <<'PYREQ' | framework::execution::run
import json,sys
command,operation,component,*args=sys.argv[1:]
print(json.dumps({'schemaVersion':'1.0','command':command,'operation':operation,'component':component,'args':args}))
PYREQ
}
