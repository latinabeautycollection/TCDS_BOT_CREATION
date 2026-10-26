# TCDS National Tax Runtime Population Runbook V1.1.0

## Purpose
Turn the reconciled ZSL1/ZSL5 tax architecture into populated runtime authority. This layer never fabricates tax facts and never treats discovery as certification.

## Required order
1. Apply existing 042/043 integration migrations.
2. Apply `044a`, `044b`, `045`, `045a`.
3. Run `runtime:acquire` against official sources.
4. Normalize source artifacts using the source-specific adapters.
5. Ingest normalized records through the strict ZSL1 lifecycle.
6. For each state/DC, approve 21 family coverage attestations plus local-authority and address-resolution evidence.
7. Confirm all 51 states are runtime-ready.
8. Publish one immutable `US_NATIONAL_TAX_CONTENT` release.
9. Create a ZSL5 V1.4 build and bind/load the publication.
10. Populate and approve independent golden/adversarial fixtures.
11. Run golden, adversarial and replay suites.
12. Perform rollback rehearsal and insert the existing `ROLLBACK_VERIFIED` QA attestation.
13. Run V1.4 certification.
14. Activate only through `zsl.zsl5_activate_v14`.

## Fail-closed rules
- Discovery candidate != tax fact.
- Downloaded artifact != certified release.
- Missing record != zero tax.
- Golden expected value may not be generated from the same ZSL5 output under test.
- A state cannot pass with fewer than 21 passing family attestations.
- Local/home-rule and address resolution are independent gates.
- National publication requires 1,071 + 51 + 51 and zero fatal conflicts.
- Candidate quote mode is certification-only; external/default quoting requires active authority.
