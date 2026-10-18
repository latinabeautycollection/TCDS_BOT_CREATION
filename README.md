# TCDS ZSL2 — Canonical U.S. Geography, PostGIS & Location Authority

**Package hardening:** `V2.1 FINAL FREEZE CANDIDATE`  
**Authoritative runtime engine:** `zsl2-v2.1.0` (aligned to the V2.1 freeze package and required by synchronized downstream ZSL3/ZSL4 bindings)

ZSL2 transforms certified ZSL1 federal evidence into canonical U.S. geography while preserving strict separation between factual geography and R1B search authorization.

## Authority flow

```text
ZSL1 certified evidence
        ↓ exact bound release/run
ZSL2 canonical identity + run-scoped revisions
        ↓ runtime checks + deterministic replay
ZSL2 certification
        ↓ explicit activation event
Effective certified canonical geography
        ↓
R1B factual candidate/proposal surface
```

## V2.1 final-freeze hardening

- exact `(source, release, ingest run)` reads only;
- run-scoped location and relationship memberships;
- immutable location revisions for mutable Census descriptions/points;
- ZSL1 revocation propagation;
- exact ZSL1 package-SHA validation;
- DB-backed runtime certification checks;
- explicit authority activation/revocation;
- HUD ratio range and per-ZIP reconciliation;
- stronger deterministic replay;
- current-authority-only spatial functions;
- R1B proposals bound to exact ZSL2 certification identity;
- advisory locking and persistent failed-run evidence;
- explicit ZSL2 RBAC and Supabase public-role hardening;
- non-destructive rollback that preserves evidence.

See `docs/FINAL-PEER-REVIEW-REMEDIATION.md` for the adversarial review findings.

## Deliberate fail-closed authority boundaries

- USPS ZIP != Census ZCTA.
- HUD-observed ZIPs remain `PENDING_USPS_ZSL3` until USPS authority is certified.
- HUD CBSA codes do not create official metro names.
- TIGER polygon geometry remains pending a certified upstream source.
- ZSL2 never writes `retail.search_locations` directly.

## Install

```bash
node scripts/verify-lock.mjs
npm ci
npm run typecheck
npm test
npm run build

for f in database/migrations/*.sql; do
  psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f "$f"
done
```

The package intentionally keeps the dependency freeze gate closed until the lock is fully resolved on an approved connected builder.

## Runtime sequence

```bash
npm run normalize
npm run certify -- <normalization-run-uuid>
npm run activate -- <normalization-run-uuid> <certification-run-uuid>
npm run r1b:proposals
```

`CERTIFIED`, `FREEZE APPROVED`, and `SAFE FOR R1B` are runtime claims and must not be asserted from static package review alone.

## V2.1 synchronized freeze contract

This freeze promotes the runtime engine contract to `zsl2-v2.1.0`, matching the package and schema release. ZSL3 and ZSL4 must bind the exact sealed ZSL2 package SHA and this exact engine identity. See `docs/SYNCHRONIZED-DEPENDENCY-CONTRACT.md`.
