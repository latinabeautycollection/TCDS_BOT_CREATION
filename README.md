# TCDS Retail R1F V2.2 — Financial Consumption HARDENED Freeze Candidate

**Status:** implementation-complete static freeze candidate; **runtime certification still required**.

This package hardens the attached R1F V2.1 financial-consumption layer against the adversarial findings in the peer-review artifact. It preserves the V2.1 evidence tables for forensic continuity, but V2.2 financial authority is produced only through the new separation-of-duties functions, causal execution receipts, normalized provider-period authority, and exact PostgreSQL NUMERIC allocation.

## V2.2 non-negotiable gates

- Exactly the current certified/effective R1D adapter scope from one attested `TCDS_BOT_CREATION` commit.
- 100% source-file SHA-256 coverage for that current scraper scope.
- 100% billing identity coverage: zone or dataset/collector/product authority for every scraper.
- Every financially certified R1D job has one immutable provider execution receipt.
- Bright Data raw responses are stored immutably; normalized cost/bandwidth buckets are derived by the database from the raw JSON.
- Opaque `back_m*` / `back_d*` buckets are **not automatically financial authority**. They must be promoted to an explicit non-overlapping provider period with semantic evidence.
- One effective provider cost authority per R1D job.
- Binding and reconciliation use the same provider-period lock.
- Currency allocation is performed only in PostgreSQL `NUMERIC`.
- Paid-cost and zero-cost provider verification are distinct states.
- Global certification fails on orphan bindings, unreconciled provider periods, broken hashes, incomplete current-scope coverage, or unbalanced provider totals.

## Production-repository accounting

The public repository authority is:

`https://github.com/latinabeautycollection/TCDS_BOT_CREATION`

V2.2 does not hard-code retailer names or a scraper count. Instead, `discover-production-scrapers.ts` reads the current certified/effective R1D adapters, hashes each corresponding entrypoint in the **actual production checkout**, and binds that exact scope to the full Git commit SHA. `register-production-scrapers.ts` requires a complete Bright Data financial mapping for every adapter in that scope.

This avoids a stale package silently omitting a scraper added, removed, renamed, or modified after packaging.

## Install order

1. `039_r1f_search_intelligence.sql`
2. `039b_r1f_v2_nationwide_economic_hardening.sql`
3. `039c_r1f_financial_consumption_layer.sql`
4. `039d_r1f_financial_consumption_v2_2_hardening.sql`

The installer applies V2.2 automatically when it sees the V2.1 financial layer.

## Required operating sequence

```text
Production repo checkout
    ↓
discover-production-scrapers.ts
    ↓
current-scope commit-bound scraper manifest
    ↓
financial mapping overrides completed
    ↓
register-production-scrapers.ts
    ↓
R1D successful execution
    ↓
record-r1d-provider-execution.ts
    ↓
Bright Data provider cost/usage collection
    ↓
DB-derived provider evidence
    ↓
promote-brightdata-cost-period.ts
    ↓
bind-brightdata-job-cost.ts
    ↓
reconcile-brightdata-zone-cost.ts
    ↓
R1F fact ingest
    ↓
certify-financial-consumption-v22.ts
    ↓
full R1F certify.ts
```

## Bright Data product-specific financial authority

V2.2 contains both provider-authoritative collectors:

- `GET /zone/cost` for zone-based billed cost and bandwidth.
- `POST /costs/export/json` for Web Scraper API and Scraper Studio cost authority.

The cost-breakdown collector supports `web_apis`, `collectors`, and `ws_api_snaps`. Bright Data's response is normalized as UTC per-day, per-resource billed USD; a top-level `total` is excluded from date parsing and must equal the daily resource sums. Dataset/day costs require complete R1D execution coverage and remain labeled allocated provider cost. Snapshot costs require one snapshot to one R1D job and are direct. V2.2 deliberately never assigns proxy-zone dollars to a dataset/collector job.

---

# TCDS Retail R1F V2 — Nationwide Economic Search Intelligence — GREEN TIER 1 Final Freeze

R1F V2 closes the Retail R-Domain learning loop.

Its objective is to answer:

> For the exact authorized product, where in the United States — retailer, ZIP, store, fulfillment mode and time — is TCDS finding the strongest acquisition economics at an acceptable search cost?

## Authority chain

```text
R1A exact product revision
        ↓
R1B retailer / ZIP / store authority
        ↓
R1C exact immutable search compilation
        ↓
R1D governed dispatch + search cost
        ↓
R1E exact returned-product qualification
        ↓
R1F V2 economic / geographic / temporal intelligence
        ↓
governed recommendation
        ↓
R1D revalidates route, budget, rate and geo authority before execution
```

R1F remains recommendation-only. It has no profit, ROI, capital, BUY/NO-BUY, purchase or checkout authority.

## True economic bargain basis

R1F V2 no longer ranks sticker price alone.

Economic acquisition amount is selected in this order:

```text
estimated_total_cost
    else
effective_price + known shipping + known tax
    else
effective_price
```

Every observation records its price basis.

Economic national baselines are restricted to:

```text
exact R1A revision
× normalized condition
× fulfillment mode
× USD currency
```

so NEW, OPEN_BOX and REFURBISHED products are not silently mixed into one reference distribution.

## Fulfillment modes

R1F retains:

```text
STORE_PICKUP
SHIP_TO_HOME
LOCAL_DELIVERY
MULTI_MODE
UNKNOWN
```

from authoritative inventory observations.

## Nationwide exploration

Unsampled authorized R1C routes continue to receive a deterministic, rotating and policy-capped `EXPLORATION_SAMPLE`, preventing early winners from starving U.S. geographic coverage.

High-value geographic expansion now carries exact authorized child compilation UUIDs. R1D does not have to infer which ZIP/store children R1F meant.

## Search-cost confidence

R1F tracks:

```text
actual-cost jobs
estimated-cost jobs
actual-cost coverage
```

The cost-efficiency score is reduced when actual billing coverage is weak.

## Collection reconciliation

For every V2 job fact:

```text
R1D metrics.records_collected
        =
authoritative PostgreSQL raw_product_captures count
```

A mismatch fails closed.

## Local-time learning

R1F stores both UTC forensic time and, when an approved R1B location has a valid `metadata.timezone`:

```text
location_timezone
local_weekday
local_hour
```

The local-time intelligence view is:

```sql
retail.r1f_local_temporal_search_intelligence
```

## Install

```bash
R1F_PACKAGE_ROOT=/absolute/path/to/package npx tsx scripts/retail-automation/r1f/install-r1f.ts
```

The installer applies the V1 base migration and then:

```text
039b_r1f_v2_nationwide_economic_hardening.sql
```

V1 ingest/build/recommend execution privileges are revoked from the runtime role.

## Policies

Use only:

```text
config/r1f-intelligence-policy-v2.example.json
config/r1f-certification-policy-v2.example.json
```

## QA fixtures

Load deterministic ranking/strategy fixtures:

```bash
npx tsx scripts/retail-automation/r1f/load-qa-fixtures.ts   config/r1f-qa-fixtures-v2.examples.json
```

Load real full-pipeline QA scenarios:

```bash
npx tsx scripts/retail-automation/r1f/load-e2e-scenarios.ts   config/r1f-e2e-scenarios-v2.example.json
```

Replace all placeholders with real succeeded QA R1D job UUIDs and controlled expected results.

## Production workflow

```bash
npx tsx scripts/retail-automation/r1f/ingest-job.ts <r1d_job_uuid>

npx tsx scripts/retail-automation/r1f/build-intelligence.ts   <r1f_v2_policy_uuid> <window_end_iso>

npx tsx scripts/retail-automation/r1f/generate-recommendations.ts   <r1f_v2_policy_uuid> <window_end_iso>
```

## Final R1D contract

R1D may consume only:

```sql
retail.r1f_effective_search_recommendations
```

The view requires current R1E/R1C authority, current R1F policy/certification, reproducible recommendation evidence, V2 engine identity, non-QA rows, and valid exact child compilation IDs for geographic expansion.

## Final certification

```bash
R1F_PACKAGE_ZIP=/absolute/path/to/TCDS_Retail_R1F_V2_NATIONWIDE_ECONOMIC_INTELLIGENCE_GREEN_TIER1_FINAL_FREEZE.zip npx tsx scripts/retail-automation/r1f/certify.ts   <certified_r1f_v2_intelligence_policy_uuid>
```

Only the immutable PostgreSQL `r1f-v2.0.0 / CERTIFIED` record may establish:

```text
CERTIFIED
FREEZE APPROVED
SAFE FOR CLOSED-LOOP R1D
R-DOMAIN READY FOR FINAL INTEGRATION CERTIFICATION
```

## V2.1 financial consumption layer

This package now includes the Bright Data zone-cost financial consumption layer in:

```text
database/migrations/039c_r1f_financial_consumption_layer.sql
```

It captures provider-authoritative `/zone/cost` evidence, immutable cost buckets, R1D job bindings, deterministic provider-cost reconciliation, and provider-backed fact provenance.

See:

```text
docs/FINANCIAL-CONSUMPTION-LAYER.md
```

Important: `/zone/cost` is for zone-based services. It must not be used to represent Web Scraper API or Scraper Studio charges; those require Bright Data Cost Breakdown Export keyed by dataset/collector.
