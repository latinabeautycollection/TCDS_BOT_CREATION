# R1E V2 Remediation Map

1. Duplicate scope is now execution/observation identity, not permanent product identity.
2. Observation duplicate qualification is serialized by PostgreSQL advisory lock and backed by a partial unique index.
3. Every V2 qualification result binds exact R1D certification run/package.
4. Result currentness requires exact current R1D binding.
5. R1E certification currentness requires the exact R1D run/package it was certified against.
6. Requalification is permitted after upstream R1D certification changes.
7. Target identity is reconstructed from immutable `search_job_compilations.normalized_job_json`, not `effective_search_routes`.
8. V2 consumes normalized identity fields including product type, model token, generation, variant, storage, RAM, platform and canonical product key when present.
9. Structured variant attributes and R1A `include_terms` are hard identity constraints.
10. Returned identifiers receive positive credit only when an expected target identifier exists and matches.
11. Exact R1D attempt evidence is copied into the immutable result and SHA-sealed.
12. `collection_run_id` uses safe UUID validation before cast/comparison.
13. Certification policy is immutable, versioned and SHA-bound to certification runs.
14. QA certification enforces per-class minimum populations.
15. Positive precision and positive recall are independent certification gates.
16. Wrong-variant false-positive rate is independently certified.
17. `expected_reason_family` must match actual reason codes.
18. Ruleset families are behaviorally enforced: confidence, duplicate, condition and bundle policies affect execution.
19. Accessory/bundle matching is token/phrase-aware rather than unrestricted substring matching.
20. Downstream authority exposes immutable returned identity snapshots, not mutable `retail_products` enrichment.
21. Ruleset certification stores ARB process-run/correlation provenance.
22. Database authority verifies permitted ARB process-run family/state.
23. Installer performs role/CREATEROLE preflight.
24. Certification includes an active two-transaction duplicate-lock concurrency test.
25. Certification/currentness includes explicit upstream-rebind invalidation semantics.
