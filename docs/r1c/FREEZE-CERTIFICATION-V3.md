# R1C V3 Freeze Certification

A legitimate R1C V3 `CERTIFIED / FREEZE APPROVED / SAFE FOR R1D` decision requires actual QA execution of this exact package.

Required runtime evidence:
1. R1B V4 scraper authority hardening 4.0.0 installed.
2. Latest R1B certification is `r1b-v4.0.0 / CERTIFIED`.
3. R1C binding references that latest R1B run.
4. V3 compiler is certified and all compiler/helper function hashes reproduce.
5. At least one effective package-tree scraper route exists.
6. At least one effective compiled R1C job exists.
7. All 56 executable adversarial gates pass.
8. Deterministic replay regenerates identical normalized job, adapter payload, and scraper authority evidence.
9. Runtime wrong-SHA package attestation fails.
10. Certification evidence manifest SHA reproduces.
11. No R1C scheduling/budget/dispatch/purchase authority exists.
12. Production rollback remains non-destructive.

Static/package review alone must not be labeled runtime certification.
