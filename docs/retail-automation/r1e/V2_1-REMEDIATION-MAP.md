# R1E V2.1 Final Freeze Remediation Map

This package closes the final peer-review items required before R1F may trust R1E.

1. All legacy V1 authority functions are explicitly revoked from R1E runtime/certifier roles.
2. R1E reads and hash-verifies the exact immutable R1A `search_target_revisions` row using `r1a_revision_id` + `r1a_revision_hash`.
3. `required_identity_terms` are separated from `search_expansion_terms`; legacy `include_terms` are not treated as hard identity requirements.
4. Storage/RAM/generation/platform/model-token values have canonical normalizers (`256 GB == 256GB`, `1 TB == 1000GB`, platform aliases, generation aliases).
5. Duplicate certification executes two full `r1e_evaluate_capture_v21()` transactions and requires one `QUALIFIED` plus one `REJECTED_DUPLICATE`.
6. A mandatory E2E corpus executes the complete production evaluator path: lineage, R1A/R1C reconstruction, product binding, observation fingerprinting, locking, persistence, evidence sealing.
7. Database Green Tier policy floors now equal the shipped certification standard rather than weaker fallback thresholds.
8. Collection-run lineage fails closed unless exactly one successful R1D attempt claims the collection run.
9. Collection-run platform must match the raw capture platform.
10. `raw_payload_hash` is preserved in forensic evidence but removed from duplicate observation identity.
11. Certification evidence binds exact fixture SHA, class, expected decision and expected reason family for both deterministic and E2E corpora.

Additional hardening:
- V2 evaluator is revoked from runtime role; V2.1 is the only production evaluator.
- R1A revision hash is recomputed for downstream currentness.
- Certification fixture results are excluded from downstream authority.
- E2E certification fixture manifests are SHA-sealed into the final certification row.
- `r1e-v2.1.0` is the only certification version accepted by final currentness.
