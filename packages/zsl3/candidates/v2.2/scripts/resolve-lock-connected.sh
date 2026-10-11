#!/usr/bin/env bash
set -euo pipefail
rm -f package-lock.json
npm install --package-lock-only --ignore-scripts
node scripts/verify-lock.mjs
