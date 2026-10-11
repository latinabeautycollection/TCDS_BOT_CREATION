#!/usr/bin/env bash
set -euo pipefail
command -v node >/dev/null
command -v npm >/dev/null
command -v psql >/dev/null
command -v unzip >/dev/null
node -e 'const [a]=process.versions.node.split(".").map(Number); if(a<22) process.exit(2)'
: "${DATABASE_URL:?DATABASE_URL required}"
: "${ZSL_GIT_SHA:?ZSL_GIT_SHA required for freeze/runtime certification}"
: "${ZSL_PACKAGE_SHA256:?ZSL_PACKAGE_SHA256 required for freeze/runtime certification}"
[[ "$ZSL_PACKAGE_SHA256" =~ ^[0-9a-f]{64}$ ]] || { echo 'ZSL_PACKAGE_SHA256 must be 64 lowercase hex' >&2; exit 3; }
[[ "$ZSL_GIT_SHA" =~ ^[0-9a-fA-F]{7,64}$ ]] || { echo 'ZSL_GIT_SHA invalid' >&2; exit 3; }
echo "ZSL1 V2.1 preflight PASS"
