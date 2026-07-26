#!/usr/bin/env bash
framework::log::emit(){ local l="$1" m="$2" c="${3:-framework}" o="${4:-unspecified}" f="${5:-{}}";python3 - "$m" "$c" "$o" "$f" <<'PY' | "$EIF_ROOT/framework/logging/log_engine_v2.py" --root "$EIF_ROOT" emit --level "$l"
import json,sys
m,c,o,f=sys.argv[1:]
try:x=json.loads(f)
except:x={'unparsedFields':'[REDACTION_FAILED]'}
x.update({'message':m,'component':c,'operation':o});print(json.dumps(x))
PY
}
framework::log::verify(){ "$EIF_ROOT/framework/logging/log_engine_v2.py" --root "$EIF_ROOT" verify --stream "${1:-framework}"; }
framework::log::seal(){ local a=(--stream "${1:-framework}");[[ -n "${2:-}" ]]&&a+=(--hmac-ref "$2");"$EIF_ROOT/framework/logging/log_engine_v2.py" --root "$EIF_ROOT" seal "${a[@]}"; }
framework::telemetry::emit(){ printf '%s' "$1"|"$EIF_ROOT/framework/telemetry/telemetry_spool.py" --root "$EIF_ROOT"; }
