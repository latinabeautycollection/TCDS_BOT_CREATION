# R1D Domain Contract

## Mission

R1D converts current R1C compiled jobs into bounded, budgeted, leased execution.

## Sole upstream authority

`retail.effective_compiled_search_jobs`

R1D never reconstructs R1A or R1B intent.

## Runtime invariants

A job is dispatchable only while all are true:

1. exact R1C V3 certification binding is current;
2. compiled job remains effective;
3. stored route/payload/compiler hashes still equal R1C authority;
4. R1D dispatch binding remains current;
5. R1B adapter/scraper authority remains execution-ready;
6. R1B file/package-tree runtime SHA attestation passes;
7. R1C compiler runtime attestation passes;
8. R1C package runtime release attestation passes;
9. GLOBAL budget exists and all applicable daily budgets can reserve the estimated cost;
10. retailer hourly/daily request limits permit another request;
11. platform and dispatch-binding concurrency permits execution;
12. circuit breaker permits execution;
13. worker owns an unexpired lease.

## Geographic escalation

R1D may change only R1D scheduling activation state.

It cannot:
- create a `search_location`;
- create or approve an R1B route;
- change an R1B location;
- change R1C payload semantics.

Escalation selects already-effective child compilations with the same target/platform and activates a bounded number at a time.

## Budget doctrine

Budget is reserved before a lease is granted.

Applicable policies are cumulative:

`GLOBAL + PLATFORM + SOURCE`

A job proceeds only if every applicable policy has sufficient remaining daily capacity.

Retries receive new budget reservations.

Pre-dispatch failures release budget.

Post-dispatch uncertainty conservatively settles the reserved estimate.

## Worker doctrine

Workers use `FOR UPDATE SKIP LOCKED` leasing.

Queue authority fields are immutable after creation.

Terminal states are irreversible.
