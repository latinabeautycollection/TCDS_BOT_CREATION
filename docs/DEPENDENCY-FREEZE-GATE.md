# Dependency Freeze Gate

The supplied source package intentionally fails closed until the npm transitive lock is fully resolved.

`node scripts/verify-lock.mjs` requires every direct and transitive package entry to contain `version`, `resolved`, and `integrity`. The current offline build environment cannot resolve registry metadata for `pg`, `@types/node`, `@types/pg`, and `typescript`.

On the approved connected builder:

```bash
./scripts/resolve-lock-connected.sh
node scripts/verify-lock.mjs
npm ci --ignore-scripts
npm run typecheck
npm run build
npm test
```

Only after `LOCK_OK` should `dependency_lock_valid` be eligible to PASS during runtime certification.
