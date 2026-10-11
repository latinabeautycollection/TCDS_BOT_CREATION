# Connected Dependency Freeze Gate

The source freeze environment used to prepare this package cannot resolve `registry.npmjs.org`. The checked-in `package-lock.json` therefore records the exact direct dependency versions but is **not** represented as a complete transitive runtime lock.

This is intentionally a runtime-freeze blocker. Before deployment certification, use an approved connected build host:

```bash
./scripts/resolve-lock-connected.sh
npm ci --ignore-scripts
npm run typecheck
npm test
npm run build
node scripts/verify-lock.mjs
```

Then regenerate the source manifest, SBOM, dependency-tree evidence, exact deployment ZIP, and `ZSL_PACKAGE_SHA256`. Do not runtime-certify an ingest run from a package whose dependency lock has not passed `verify-lock.mjs`.
