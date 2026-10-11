#!/usr/bin/env bash
set -euo pipefail
rm -f package-lock.json
npm install --package-lock-only --ignore-scripts --no-audit --no-fund
node scripts/verify-lock.mjs
npm ci --ignore-scripts --no-audit --no-fund
npm run typecheck
npm test
node scripts/generate-source-manifest.mjs
node scripts/verify-source-manifest.mjs
echo "Connected dependency freeze complete. Repackage and reseal the ZIP SHA before certification."
