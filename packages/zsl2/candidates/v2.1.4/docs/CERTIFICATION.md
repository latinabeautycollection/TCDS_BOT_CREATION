# ZSL2 Green Tier 1 Certification Doctrine

Static implementation quality is separate from runtime certification.

Runtime certification requires this exact package/deployment SHA, exact upstream source certifications, successful normalization/reconciliation, no unresolved FATAL conflicts, 100% identity-hash coverage, 100% raw-record lineage coverage, zero orphan relationships, deterministic replay, spatial sanity checks, RBAC tests, rollback test, and insertion of an immutable `zsl.zsl2_certification_runs` row with status `CERTIFIED`.

No response, dashboard, or downstream system may claim ZSL2 `FREEZE APPROVED` merely because source code passes static tests.
