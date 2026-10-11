#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
# Run only in the approved connected build environment. Direct dependencies are
# exact-pinned in package.json; this resolves and seals the complete transitive graph.
rm -f package-lock.json
npm install --package-lock-only --ignore-scripts
node scripts/verify-lock.mjs
sha256sum package-lock.json > evidence/PACKAGE_LOCK_SHA256.txt
printf '%s\n' 'Dependency lock resolved. Re-run npm ci, tests, build, manifest and package SHA sealing before runtime certification.'
