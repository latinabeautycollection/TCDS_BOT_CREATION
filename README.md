# TCDS ZSL3 V2.2 — Geographic Economic & Market Context Intelligence Authority

**Package:** `@tcds/zsl3-economic-intelligence`  
**Version:** `2.2.0`  
**Engine:** `zsl3-v2.2.0`

ZSL3 is the third ZSL authority layer:

`ZSL1 certified external evidence → ZSL2 certified canonical geography → ZSL3 factual/derived economic context → future ZSL cold-start intelligence`.

## Ownership

ZSL3 owns ACS demographic/economic facts, BEA RPP context, CBP/ZBP business-density facts, NAICS-governed context, governed derived features, snapshots, confidence/freshness/missingness, replay, certification and activation.

It does **not** acquire external data, create canonical geography/ZIP/metro authority, authorize retailer search routes, schedule R1D work, compile R1C requests, qualify R1E products, perform R1F outcome learning, make BUY/NO-BUY decisions, execute checkout, or own Warehouse operations.

## V2.2 final hardening

V2.2 specifically prevents false certification by:
- reading ACS metadata from ZSL1 schema-validation evidence;
- verifying exact ZSL1 and ZSL2 package identities;
- making runtime certification checks attempt-scoped;
- independently replaying percentile cohorts/formulas;
- recomputing confidence/freshness from persisted evidence;
- computing geography-aware source/fact/derived/location coverage;
- binding exact source-vintage sets into snapshots;
- preserving every BEA MSA reconciliation disposition;
- preserving ACS missing/invalid observations as explicit missingness;
- measuring NAICS, suppression, orphan, conflict, RBAC, migration, dependency and rollback gates.

## Required upstream prerequisite

Active policy requires certified ZSL1 `CENSUS_CBP` and `CENSUS_ZBP`. If unavailable, ZSL3 correctly fails closed. Do not weaken the policy.

## Runtime lifecycle

`CREATED → BINDING → NORMALIZING → VALIDATING → DERIVING → SNAPSHOTTING → REPLAYING → RECONCILED → runtime checks → CERTIFIED → explicit ACTIVATED`

Every certification is bound to one immutable `runtime_check_run_id`.

## Build

```bash
npm ci --ignore-scripts
npm run typecheck
npm run build
npm test
node scripts/generate-manifests.mjs
node scripts/verify-lock.mjs
```

The connected builder must resolve the complete lock before runtime certification.

## Status doctrine

This package may be called **Green Tier 1 implementation final / source freeze candidate** only after all static gates pass.

It is **not runtime certified, production freeze approved, or safe for ZSL4 production dependency** until the exact package passes real Supabase/PostgreSQL runtime certification and is explicitly activated.
