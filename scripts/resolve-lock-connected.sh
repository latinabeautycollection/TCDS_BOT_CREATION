#!/usr/bin/env bash
set -euo pipefail
rm -f package-lock.json
npm install --package-lock-only --ignore-scripts --no-audit --no-fund
node scripts/verify-lock.mjs
npm ci --ignore-scripts --no-audit --no-fund
npm run typecheck
npm test
npm run build
