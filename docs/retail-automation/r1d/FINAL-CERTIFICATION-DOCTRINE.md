# R1D V2 Final Certification Doctrine

This package is the finalized R1D V2 implementation.

The software may be called **10/10 GREEN TIER 1 implementation-ready** after static/package review, but the database may record `CERTIFIED / FREEZE APPROVED` only when the exact release ZIP passes the runtime certification suite.

## Runtime certification prerequisites

1. Exact R1A/R1B/R1C upstream authority is current.
2. Latest R1C certification is `r1c-v3.0.0 / CERTIFIED`.
3. Exact R1D release ZIP is supplied to `R1D_PACKAGE_ZIP`.
4. One current certified dispatch binding exists for every production adapter in scope.
5. Every production platform has an explicit rate policy.
6. Every applicable source has a bounded active cost profile.
7. Exactly one GLOBAL DAILY and one GLOBAL MONTHLY budget exist.
8. Production schedule state covers every effective compiled job.
9. No unresolved cost-model violation exists.
10. V2 adversarial tests pass.
11. Isolated QA concurrency tests pass.
12. Canonical evidence SHA reproduces.
13. Certification row and ARB process-run terminal state commit atomically.
14. Certification/history ledgers remain append-only.

## Certification command

```bash
R1D_PACKAGE_ZIP=/absolute/path/to/TCDS_Retail_R1D_GREEN_TIER1_RUNTIME_SAFETY_HARDENED_V2_CERTIFICATION_FINAL.zip R1D_CONCURRENCY_WORKERS=8 npx tsx scripts/retail-automation/r1d/certify.ts
```

A successful run writes an immutable `retail.r1d_certification_runs` row with `certification_version='r1d-v2.0.0'` and `certification_status='CERTIFIED'`.

No static review, package name, README statement, or developer assertion substitutes for that database evidence.
