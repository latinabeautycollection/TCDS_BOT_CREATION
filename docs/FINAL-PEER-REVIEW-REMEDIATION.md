# ZSL2 V2.1 Final Freeze — Adversarial Peer Review Remediation

The attached V1 package was a strong architectural prototype but was not safe for final freeze. The final hardening pass identified and remediated the following material defects.

## P0 remediated

1. **Certified-view leakage across runs** — the prior `certified_canonical_locations` view exposed every active global location whenever any normalization run was certified. V2.1 introduces run-scoped location/relationship memberships plus an explicit active authority event. Only the activated certified run is visible downstream.
2. **Unbound source mixing** — the prior normalizer selected `zsl.certified_release_records` by source key alone, so multiple certified releases could be mixed after binding one release. V2.1 reads only the exact `(source_key, release_id, ingest_run_id)` bound to the normalization run.
3. **Upstream certification revocation did not propagate** — V2.1 validates the latest ZSL1 certification event for every bound ingest run on certification and every downstream authority read.
4. **Certification trusted caller booleans** — V2.1 persists immutable DB-backed runtime checks; the certification trigger requires the complete named check set and zero failures.
5. **Package/policy mismatch could certify** — the certification guard now requires the certification package SHA, policy SHA, and engine identity to equal the normalization run.
6. **No exact source-set gate** — runtime certification requires the exact governed six-source set, not merely a count of six bindings.
7. **HUD ratios were neither bounded nor reconciled** — V2.1 enforces `[0,1]` ratio bounds and validates per-ZIP ratio sums by relationship/release within governed tolerance.
8. **Mutable names/points were embedded in identity** — stable canonical identity is now separated from run-scoped descriptive/point revisions, allowing legitimate Census name/coordinate evolution without false identity drift.
9. **Replay did not validate ratio or revision evidence** — replay now verifies stable identity hashes, revision hashes, relationship keys/types, and all HUD ratio values.
10. **Rollback was broken by schema-state CHECK** — the old rollback attempted to write an invalid engine value. V2.1 rollback removes authority surfaces without mutating historical evidence or violating the schema-state constraint.

## P1 remediated

- normalization obtains a PostgreSQL advisory lock;
- failed normalization runs persist a FAILED forensic state rather than disappearing with a transaction rollback;
- records are paged from the bound certified source set instead of loading an entire source into memory;
- spatial services resolve only the effective certified snapshot and validate radius/coordinate arguments;
- R1B proposals bind the exact ZSL2 normalization/certification identity;
- explicit ACTIVATE/REVOKE authority-event CLIs were added;
- PUBLIC execution on security-sensitive functions is revoked;
- dedicated ZSL2 NOLOGIN roles and Supabase anon/authenticated revocations are included;
- an actual ZSL1 package-SHA runtime binding check is performed against the ZSL1 ingest runs.

## Deliberate authority gaps retained

- USPS Five-Digit ZIP remains a later authority; HUD-observed ZIPs are not called USPS-validated.
- Official CBSA names remain pending a certified Census/OMB delineation source.
- TIGER/Line polygon authority remains pending a certified spatial source.

These are deliberate fail-closed gaps, not missing implementation claims.
