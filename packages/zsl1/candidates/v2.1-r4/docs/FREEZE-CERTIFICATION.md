# ZSL1 V2.1 FINAL FREEZE DOCTRINE

## Freeze decision boundary

Static source review can establish implementation readiness. It cannot establish runtime source certification.

The exact deployed ZIP must be identified by `ZSL_PACKAGE_SHA256`; the deployed repository revision must be identified by `ZSL_GIT_SHA`. A runtime certification cannot pass if either identity is absent or mismatched.

## Mandatory runtime gates

1. Clean install against the actual Supabase PostgreSQL project.
2. Upgrade test from ZSL1 V2 to V2.1.
3. RBAC/grant verification under the actual Supabase database owner.
4. Ingest one real release for every governed source/geometry profile.
5. Artifact byte count and SHA reproduction.
6. Source-specific schema validation PASS.
7. Run membership equals parsed record count.
8. Deterministic parser replay digest equals database ordered digest.
9. Required audit-event coverage = 100%.
10. Secret leakage scan = PASS.
11. Concurrent same-release ingestion rejection.
12. Truncated artifact / wrong MIME / wrong magic fail-closed tests.
13. ZIP path traversal / expanded-size / compression-ratio adversarial tests.
14. Schema drift / required-field removal fail-closed tests.
15. Release identity mismatch tests for HUD year/quarter and BEA/ACS vintages.
16. Governance version-reuse rejection.
17. Certification insert-guard negative tests.
18. Revocation test proving downstream certified view removes a revoked run.
19. Supabase TLS and least-privilege tests.
20. Non-destructive rollback test.

Only after these gates pass may a runtime certification row be treated as authority for ZSL-B2.
