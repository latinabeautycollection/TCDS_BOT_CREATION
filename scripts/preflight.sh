#!/usr/bin/env bash
set -euo pipefail
node scripts/verify-lock.mjs
npm run typecheck
npm run build
npm test
