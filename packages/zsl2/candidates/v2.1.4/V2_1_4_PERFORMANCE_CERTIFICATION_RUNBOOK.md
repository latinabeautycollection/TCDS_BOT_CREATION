# V2.1.4 performance/certification runbook

1. Verify live production migration history retains its existing 009/010 hashes.
2. Apply only V2.1.4 forward migrations 011-016 in staging first.
3. Supply the exact signed ZSL1 authority decision JSON, Ed25519 signature, Anthony Malone governance public key, and pinned public-key SHA.
4. Start a new V2.1.4 normalization run; do not reuse REV9 performance certification.
5. Run all six exact source bindings with keyset pagination.
6. Capture `zsl2_performance_measurements` by operation and `NORMALIZE_PAGE`.
7. Execute `database/runtime/005_v2_1_4_performance_plans.sql` for real `EXPLAIN (ANALYZE, BUFFERS, WAL, SETTINGS)` evidence.
8. Require page P99 < 60 seconds and hard max < 120 seconds.
9. Run deterministic replay, territorial pending-evidence checks, RBAC, activation/revocation, rollback and downstream contract checks.
10. Finalize certification only when every required V2.1.4 check is present and PASS.
