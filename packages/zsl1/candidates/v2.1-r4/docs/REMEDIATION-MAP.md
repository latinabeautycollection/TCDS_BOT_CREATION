# V1 → V2 Remediation Map

1. Python runtime → TypeScript/Node 22 adapters.
2. `vintage=current` → explicit source release key; HUD uses year+quarter.
3. Batch-owned raw rows → content-addressed raw records + release memberships.
4. Partial-commit poisoning → load in transaction; release membership independent from content identity.
5. Secret leakage → central redaction before persisted errors/logs.
6. Parsed-only custody → original artifact retained with SHA/size/URL/storage URI.
7. No schema authority → schema contracts + fail-closed validation.
8. Ambiguous COMPLETED → explicit state machine and independent certification.
9. No Supabase RBAC → schema revoke, role grants and immutable triggers.
10. State-only ACS → State/County/Place/ZCTA adapter profiles.
11. Hard-coded source semantics → governed config/schema contracts.
12. Regex BEA/landing-page FAF discovery → governed table/release parameters.
13. One-row inserts → batched set-based insertion architecture.
14. No retry → bounded retry/backoff with permanent-error fail closed.
15. No concurrency lock → PostgreSQL advisory lock.
16. No duplicate/source-release separation → source release/retrieval/artifact split.
17. Weak DB constraints → SHA, status, count, JSON and time checks.
18. Mutable evidence → immutable triggers and append-only audit ledger.
19. Missing software provenance → app/git/package/policy/adapter identities.
20. Loose dependencies/Python cache → exact npm versions, lock file, package hygiene.
21. No tests → Node test suite and static controls.
22. No certification engine → immutable certification evidence and certified-only view.
