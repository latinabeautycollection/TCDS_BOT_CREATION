# Installation runbook
1. Verify repo head and no migrations numbered 042/043 already exist.
2. Backup/clone staging database.
3. Apply 042a→042d in order. Run ZSL1 ingestion/population until DB readiness reports 1071/1071 + 51/51 + 51/51.
4. Create certified `US_NATIONAL_TAX_CONTENT` publication.
5. Apply 043→043c.
6. Create a v1.4 build with non-zero package/policy hashes and current ZSL2 binding.
7. Bind/load the national publication; verify exactly 21 source roles.
8. Execute golden/adversarial quotes and runtime certification.
9. Rehearse non-destructive rollback. Add rollback attestation, rerun certification.
10. Activate only via `zsl.zsl5_activate_v14`.
11. Production sign-off is separate from build success.
