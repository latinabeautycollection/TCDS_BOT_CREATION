# TCDS Retail R1E V2.1 — GREEN TIER 1 FINAL FREEZE

R1E V2.1 is the final Exact Product Identity & Observation Qualification implementation.

It answers:

> Did this exact R1D retail collection return the exact product identity authorized by the immutable R1A/R1C search intent, and is this a distinct economic observation rather than a duplicate record?

R1E owns identity/variant/accessory/condition/observation qualification only. It does not own demand, profit, ROI, capital, BUY/NO-BUY, purchasing or checkout.

## Authority chain

```text
R1A immutable target revision
        ↓
R1B retailer / ZIP / store authority
        ↓
R1C immutable compiled execution snapshot
        ↓
R1D certified collection attempt
        ↓
R1E V2.1 exact identity + observation qualification
        ↓
R1F geographic/search yield intelligence
```

## Install

```bash
R1E_PACKAGE_ROOT=/absolute/path/to/package npx tsx scripts/retail-automation/r1e/install-r1e.ts
```

The installer applies:
- `038_r1e_product_match_qualification.sql`
- `038b_r1e_v2_exact_identity_observation_hardening.sql`
- `038c_r1e_v21_final_freeze_hardening.sql`

It also verifies legacy V1/V2 evaluator authority is revoked.

## Exact R1A identity

V2.1 no longer depends on R1C carrying every normalized identity field.

The evaluator follows `search_job_compilations.r1a_revision_id` and `r1a_revision_hash` back to the immutable `retail.search_target_revisions` row and recomputes the R1A revision hash before qualification.

R1A search semantics are separated:

```text
required_identity_terms  → hard qualification constraint
search_expansion_terms   → search/discovery aid only
```

Legacy `include_terms` are not silently treated as mandatory identity.

## Canonical variant identity

V2.1 canonicalizes:
- model token
- generation
- storage
- RAM
- platform aliases

Examples:

```text
256GB  == 256 GB
1TB    == 1000GB
PS5    == PlayStation 5
13th Gen == 13th Generation
```

Structured hard attributes remain fail-closed when specified by the R1A target.

## Observation duplicates

Duplicate identity is based on the economic observation:

```text
collection_run
+ exact compilation
+ location / ZIP / store
+ collection source
+ platform product key
+ canonical price / tax / shipping / inventory / availability
```

`raw_payload_hash` is kept in forensic evidence but deliberately excluded from duplicate identity.

The same product in another store, ZIP, price, inventory state, or later collection remains a legitimate observation.

## Lineage

R1E fails closed unless:
- the capture has a collection run
- collection-run platform matches capture platform
- exactly one successful R1D attempt claims that collection-run UUID

Zero matches or multiple matches are lineage failures.

## Production evaluator

Runtime uses only:

```sql
retail.r1e_evaluate_capture_v21(...)
```

Legacy V1 and V2 evaluator privileges are revoked from operational R1E roles.

## QA and certification

Load deterministic matching fixtures, E2E capture fixtures and duplicate-race pairs.

```bash
npx tsx scripts/retail-automation/r1e/load-qa-fixtures.ts   config/r1e-deterministic-fixtures-v21.examples.json

npx tsx scripts/retail-automation/r1e/load-e2e-fixtures.ts   <e2e-fixtures.json>

npx tsx scripts/retail-automation/r1e/load-duplicate-race-fixtures.ts   <race-fixtures.json>
```

Register the final policy using:

```text
config/r1e-certification-policy-v21.example.json
```

Then certify the exact ZIP:

```bash
R1E_PACKAGE_ZIP=/absolute/path/to/TCDS_Retail_R1E_V2_1_GREEN_TIER1_FINAL_FREEZE.zip npx tsx scripts/retail-automation/r1e/certify.ts   <ruleset_uuid>
```

Only a successful immutable `r1e-v2.1.0 / CERTIFIED` record activates downstream authority.

## R1F contract

R1F may consume only:

```sql
retail.r1e_effective_qualified_products
```

Certification-only QA rows and stale upstream results are excluded automatically.
