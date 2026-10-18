#!/usr/bin/env bash
set -euo pipefail
: "${DATABASE_URL:?DATABASE_URL required}"
node scripts/verify-lock.mjs
node scripts/verify-source-manifest.mjs
npm ci --ignore-scripts
npm run typecheck
npm test
npm run build
for f in database/migrations/*.sql; do
  echo "Applying $f"
  psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f "$f"
done
