#!/usr/bin/env bash
# shellcheck shell=bash
eif_config_engine(){ printf '%s/framework/config/config_engine.py' "$EIF_ROOT"; }
eif_load_config(){
  EIF_RESOLVED_CONFIG="$EIF_RUNTIME_DIR/resolved-config.json"
  local a=(resolve --root "$EIF_ROOT" --environment "$EIF_ENVIRONMENT" --hostname "$EIF_SHORT_HOSTNAME" --output "$EIF_RESOLVED_CONFIG")
  [[ -n "${EIF_COMPONENT:-}" ]] && a+=(--component "$EIF_COMPONENT")
  [[ -n "${EIF_RUNTIME_CONFIG:-}" ]] && a+=(--runtime "$EIF_RUNTIME_CONFIG")
  [[ "${EIF_VERIFY_SECRETS:-false}" == true ]] && a+=(--verify-secrets)
  "$(eif_config_engine)" "${a[@]}" >/dev/null
  export EIF_RESOLVED_CONFIG
}
eif_config_get(){ python3 - "$EIF_RESOLVED_CONFIG" "$1" "${2:-}" <<'PYEOF'
import json,sys
p,k,d=sys.argv[1:]; x=json.load(open(p))
try:
  for q in k.split('.'): x=x[q]
except (KeyError,TypeError): print(d); raise SystemExit
print(json.dumps(x) if isinstance(x,(dict,list)) else str(x).lower() if isinstance(x,bool) else x)
PYEOF
}
eif_config_validate_file(){ "$(eif_config_engine)" validate --input "$1" --schema "$2"; }
eif_config_render(){ "$(eif_config_engine)" render --input "$EIF_RESOLVED_CONFIG" --key "$1" --output "$2" --mode "${3:-0640}"; }
eif_config_snapshot(){ local o="$1"; shift; "$(eif_config_engine)" snapshot --output "$o" "$@"; }
eif_config_check_drift(){ "$(eif_config_engine)" drift --snapshot "$1"; }
