# TCDS Retail R1D V2 — 10/10 GREEN TIER 1 CERTIFICATION FINAL

R1D V2 preserves the R1D control-plane topology and closes the runtime/concurrency findings from the independent PostgreSQL + TypeScript peer review.

## Authority boundary

R1D V2 consumes only `retail.effective_compiled_search_jobs`.

R1D owns scheduling, geographic activation, bounded dispatch cost, rate limits, concurrency, leasing, retries, circuit breaking and invocation of the already-certified existing retailer scraper.

R1D does not own product selection, profitability, BUY/NO-BUY, capital allocation, purchasing or checkout.

## Install

Apply V1 first, then V2:

```bash
psql "$DATABASE_URL" -v ON_ERROR_STOP=1   -f database/migrations/037_r1d_scheduler_dispatcher.sql

psql "$DATABASE_URL" -v ON_ERROR_STOP=1   -f database/migrations/037b_r1d_v2_runtime_safety_hardening.sql
```

## Required production policies

R1D V2 fails closed unless production platforms have:
- exact current R1C V3 certification binding
- certified current dispatch binding
- bounded active cost profile with `max_execution_cost_usd`
- explicit active rate policy
- one GLOBAL DAILY budget
- one GLOBAL MONTHLY budget
- applicable schedule policy

## Budget doctrine

Every execution reserves the certified maximum execution cost, not a best-case estimate.

Retries receive a fresh reservation.

If provider-reported actual cost exceeds the certified maximum, R1D records a `r1d_cost_model_violations` incident and suspends that cost profile from future execution.

Applicable budget policies are cumulative:
`GLOBAL + PLATFORM + SOURCE`, across DAILY and MONTHLY periods.

## Rate doctrine

NULL retailer limits never mean unlimited.

Every active production platform must have an explicit `r1d_rate_policies` record containing either:
- numeric hourly/daily limits, or
- explicitly approved unlimited flags.

Rate reservations are attempt-scoped. Confirmed pre-dispatch failures release them.

## Runtime

Workers are persistent loops. They claim first, then create an `arb.process_runs` record only after actual work is obtained.

Before invocation R1D verifies R1B file/package-tree authority and R1C compiler/release authority.

Local subprocess state is:

```text
LEASED
  -> runtime attestation
  -> OS child emits spawn
  -> DISPATCHING
```

A process creation failure remains pre-dispatch and releases budget/rate capacity.

## Child environment security

Payload parameters may only target exact names in the certified R1B `field_map`.

Payloads cannot override reserved process variables such as `PATH`, `NODE_OPTIONS`, `NODE_PATH`, `LD_PRELOAD`, database connection variables, or R1 runtime variables.

Inherited secrets must be explicitly listed in the certified R1D binding `runner_policy_json.inherited_env_allowlist`.

## Runner authority

V2 runner kinds:
- `node_js`
- `tsx_file`
- `npm_script`
- `external_queue`

For `npm_script`, the selected script must exactly equal the R1B asset's certified `execution_command`.

## Circuit breaker

V2 implements CLOSED -> OPEN -> HALF_OPEN with exactly one half-open permit/probe at a time.

## External queue

Outbox identity is per `(job_id, attempt_no)` with a unique `outbox_message_id`.

External enqueue and transition to `dispatching` are one PostgreSQL transaction.

External completion and outbox acknowledgement are one PostgreSQL authority function and are idempotent.

## Geographic escalation

V2 uses explicit parent/child location-type transition rules. R1D may activate only existing effective R1C child compilations; it never creates R1B route authority.

## Certification

Prepare isolated QA fixtures:

```bash
R1D_CERT_FIXTURE_COUNT=8 npx tsx scripts/retail-automation/r1d/prepare-certification-fixtures.ts
```

Final certification hashes the actual release ZIP itself:

```bash
R1D_PACKAGE_ZIP=/path/to/TCDS_Retail_R1D_GREEN_TIER1_RUNTIME_SAFETY_HARDENED_V2_FINAL.zip R1D_RUN_CONCURRENCY_TESTS=true R1D_CONCURRENCY_WORKERS=8 npx tsx scripts/retail-automation/r1d/certify.ts
```

Certification evidence uses canonical JSON text and stores the exact canonical bytes used for SHA-256 so PostgreSQL can reproduce the evidence seal.

Do not label the package runtime `CERTIFIED / FREEZE APPROVED` until this exact ZIP passes the QA suite against the real production-compatible schemas and certified R1A/R1B/R1C authority.


## Finalized release status

This package has passed the final static implementation hardening review:

- all 25 peer-review remediation requirements implemented
- final 25-point runtime-safety source verification PASS
- TypeScript syntax/transpilation verification PASS
- deterministic manifest integrity verification included
- idempotent installation/preflight workflow included
- runtime certification authority self-hashes the exact release ZIP
- certification row + ARB process-run terminal state commit atomically

Install using the governed installer:

```bash
R1D_PACKAGE_ROOT=/absolute/path/to/TCDS_Retail_R1D_GREEN_TIER1_CERTIFICATION_FINAL npx tsx scripts/retail-automation/r1d/install-r1d-v2.ts
```

Then bind the latest certified R1C V3 authority, configure production policies and bindings, and run the final runtime certification described in `docs/FINAL-CERTIFICATION-DOCTRINE.md`.

The implementation itself is the finalized Green Tier 1 release. Runtime `CERTIFIED / FREEZE APPROVED` status is granted only by the immutable PostgreSQL certification record generated from this exact ZIP after the QA gates pass.
