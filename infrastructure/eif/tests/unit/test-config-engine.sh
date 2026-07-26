#!/usr/bin/env bash
set -Eeuo pipefail
R="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)"
T="$(mktemp -d)"
trap 'rm -rf "$T"' EXIT
E="$R/framework/config/config_engine.py"

"$E" resolve --root "$R" --environment test --hostname none --output "$T/r.json" >/dev/null
"$E" validate --input "$T/r.json" --schema "$R/schemas/framework-config.schema.json" >/dev/null
cat > "$T/o.json" <<'JSON'
{"render":{"sample":"hello\n"}}
JSON
"$E" resolve --root "$R" --environment test --hostname none --runtime "$T/o.json" --output "$T/x.json" >/dev/null
"$E" render --input "$T/x.json" --key render.sample --output "$T/a" >/dev/null
"$E" snapshot --output "$T/s.json" "$T/a" >/dev/null
"$E" drift --snapshot "$T/s.json" >/dev/null
printf changed > "$T/a"
set +e
"$E" drift --snapshot "$T/s.json" >/dev/null
rc=$?
set -e
[[ $rc -eq 10 ]]
echo 'PASS: configuration engine'
