#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
./scripts/preflight.sh
node scripts/verify-lock.mjs
npm ci --ignore-scripts
npm run typecheck
npm test
psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f database/migrations/001_zsl1_green_tier1_v2.sql
psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f database/migrations/002_zsl1_v21_freeze_hardening.sql
npm run bootstrap
echo "ZSL1 V2.1 installed. Runtime source certification is still required."
