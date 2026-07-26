#!/usr/bin/env bash
set -Eeuo pipefail
R="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)"; T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
printf '{"components":{"redis":{"password":"secret://env/TCDS_TEST_SECRET"}}}
' > "$T/o.json"; export TCDS_TEST_SECRET='do-not-persist'
"$R/framework/config/config_engine.py" resolve --root "$R" --environment test --hostname none --runtime "$T/o.json" --output "$T/r.json" --verify-secrets >/dev/null
grep -q 'secret://env/TCDS_TEST_SECRET' "$T/r.json"; ! grep -q 'do-not-persist' "$T/r.json"; echo 'PASS: secret references'
