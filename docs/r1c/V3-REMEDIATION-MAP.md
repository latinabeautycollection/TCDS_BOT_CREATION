# R1C V3 Remediation Map

1. Requires R1B V4 hardening 4.0.0.
2. Requires latest R1B certification `r1b-v4.0.0`.
3. Uses R1B-compatible file/package-tree runtime hashing.
4. Certified scraper contract `required_fields` are mandatory minimums.
5. Profile requirements can only add constraints.
6. Optional geo/result fields require mapping + capability.
7. Adds `argv` transport.
8. ARB process runs are created outside rollbackable business transactions.
9. Adds atomic governed R1B rebinding.
10. Rebinding writes immutable binding history and audit.
11. Fixes exact-version migration view idempotency.
12. Adds versioned compile profiles with one active profile per route.
13. Adds overlapping token-level query deduplication.
14. Query policy now changes deterministic query behavior.
15. Compilation evidence explicitly carries scraper asset/contract identity.
16. Certification includes R1B V4-specific adversarial gates.
17. Package-tree wrong-SHA runtime test included.
18. Contract-required-field omission fails closed.
19. Unsupported optional geo fields are not emitted.
20. Adds pgcrypto schema compatibility wrapper.
21. Additional hardening: helper-function definitions are also cryptographically bound into compiler authority.
