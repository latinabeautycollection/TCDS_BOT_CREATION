#!/usr/bin/env bash
set -euo pipefail
: "${DATABASE_URL:?DATABASE_URL required}"
node scripts/verify-lock.mjs
node scripts/verify-source-manifest.mjs
npm ci --ignore-scripts
npm run typecheck
npm run build
npm test
./scripts/migrate.sh
