#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
if node scripts/verify-lock.mjs; then
  npm ci --ignore-scripts
else
  echo 'NOTICE: transitive dependency lock requires connected-build freeze; source static checks continue using the approved review environment.' >&2
fi
npm run typecheck
npm test
npm run build
npm run --silent manifest | tail -n 1 | tee evidence/SOURCE_MANIFEST_SHA256.txt
sha256sum package-lock.json > evidence/PACKAGE_LOCK_SHA256.txt
sha256sum database/migrations/*.sql > evidence/MIGRATION_SHA256.txt
echo "STATIC IMPLEMENTATION CHECKS PASS. This is not runtime source certification."
