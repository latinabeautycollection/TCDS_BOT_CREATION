# R1F V2 Green Tier 1 Freeze Certification

A production freeze requires both deterministic algorithm certification and actual full-pipeline QA execution.

## Deterministic corpus

Minimum:
- 625 fixtures total
- all required classes at or above the database-enforced minimum
- score/recommendation expectations = 100%
- nationwide ranking = 100%
- strategy convergence = 100%
- deterministic replay = 100%

Required classes:
- high opportunity
- low opportunity
- insufficient sample
- high cost
- strong bargain
- weak availability
- exploration
- nationwide ranking
- strategy convergence

## Full-pipeline corpus

Minimum:
- 10 E2E scenarios
- 50 actual succeeded R1D QA jobs
- 100% E2E scenario accuracy
- non-zero R1F V2 facts, observations, snapshots and recommendations
- collection reconciliation = 100%
- fact/snapshot/recommendation SHA coverage = 100%
- economic-dimension coverage = 100%
- actual search-cost coverage >= 80%
- metro/postal/store timezone coverage >= 95%
- recommendation concurrency/idempotency = PASS

Every E2E scenario executes:

```text
R1D succeeded QA job
→ current R1E V2.1 results
→ r1f_ingest_completed_job_v2()
→ immutable V2 job/observation facts
→ r1f_build_intelligence_v2()
→ V2 intelligence snapshot
→ r1f_generate_recommendations_v2()
→ immutable recommendation
```

The certification manifest seals the SHA chain across all four stages.

## R1F V2.2 Financial Consumption supplemental freeze gates

V2.2 financial authority is not freeze-approved until all of the following pass against the exact deployed production commit:

- exact commit-bound coverage of the current certified/effective R1D scraper scope;
- all current-scope source SHA-256 values valid against the production checkout;
- all current-scope scraper identities have authoritative platform/provider/billing mappings;
- every current-scope scraper has at least one immutable provider execution receipt;
- every current-scope scraper has at least one provider-cost allocation;
- no generic worker direct DML on financial-authority tables;
- no PUBLIC execution on V2.2 `SECURITY DEFINER` mutation functions;
- 100% raw-provider/hash integrity;
- no overlapping active provider authority periods;
- one effective provider financial authority per R1D job;
- 100% provider-period cost conservation;
- zero orphan bindings and zero unreconciled active authority periods;
- at least one `PROVIDER_PAID_COST_RECONCILED` sample in addition to any zero-cost evidence;
- `financial-adversarial-tests-v22.ts`, `certify-financial-consumption-v22.ts`, and full `certify.ts` all pass.
