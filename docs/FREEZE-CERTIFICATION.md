# R1B V3 Freeze Certification Requirements

Certification is legitimate only when all are true:

1. Exact R1A schema/package/evidence/view identity bound and current.
2. At least one adapter is certified with code/input/capability/evidence fingerprints.
3. Certified adapter has explicit source/method capabilities or certified wildcard flags.
4. At least one approved route is current and effective.
5. All active negative mutation tests execute and pass.
6. Static database assertions pass.
7. Runtime adapter SHA attestation succeeds against deployed artifact.
8. Every authority mutation has ARB process-run/correlation provenance.
9. Production rollback preserves evidence.
10. Certification run is sealed in `retail.r1b_certification_runs`.
