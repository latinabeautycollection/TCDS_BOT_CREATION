# ZSL3 V2.1 Remediation Map

| Finding | Severity | Root cause | Remediation | Code/migration | Test | Gate | Status |
|---|---|---|---|---|---|---|---|
| Invalid UNIQUE expression | P0 | table-level expression constraint | replaced with unique expression index | 004_zsl3_fact_authority.sql | sql-static.test.ts | migration install | PASS |
| ZSL1 package identity | P0 | binding did not enforce SHA | exact package SHA enforced in source binding | source-binding.service.ts | upstream.test.ts | exact_zsl1_package | PASS |
| Upstream revocation | P0 | authority ignored latest ZSL1 events | zsl3_bindings_still_valid + current authority fail-closed | 008_zsl3_upstream_validity.sql | upstream.test.ts | zsl1_bindings_current | PASS |
| ACS metadata missing | P0 | tables declared but not populated | metadata population + label validation | acs-metadata.service.ts | metadata.test.ts | acs_metadata_complete | PASS |
| BEA/CBP lineage | P0 | normalizers skipped lineage | shared insertFact creates lineage for all source facts | facts.ts | lineage.test.ts | raw_fact_lineage_100 | PASS |
| Derived lineage | P0 | feature lineage not written | every derived feature records exact inputs | feature-engine.ts | lineage.test.ts | derived_feature_lineage_100 | PASS |
| Replay fake | P0 | snapshot hash used as formula replay | dedicated formula/snapshot/freshness/confidence/missingness replay | replay.service.ts | replay.test.ts | deterministic_feature_replay_100 | PASS |
| ZIP/ZCTA | P0 | ZBP attached to ZCTA | POSTAL_CODE scope resolves to US:ZIP | geography.ts | geography.test.ts | zbp_postal_resolution | PASS |
| NAICS vintage | P0 | 2017 source mixed with 2022 codes | explicit vocabulary and no implicit crosswalk | business.ts/naics-policy.json | naics.test.ts | naics_vocabulary_valid | PASS |
| BEA MSA ambiguity | P0 | MSA assumed CBSA | accept only authoritative ZSL2 CBSA mapping | bea.ts | bea.test.ts | bea_msa_authority_valid | PASS |
| Freshness/confidence hardcoded | P0 | constant values | governed deterministic engines | freshness.ts/confidence.ts | replay.test.ts | freshness_replay_100/confidence_replay_100 | PASS |
| Economic pressure missing | P0 | policy/runtime mismatch | implemented and replayed | feature-engine.ts | feature.test.ts | feature_definition_coverage_100 | PASS |
| Authority event bug | P1 | latest global event could revoke unrelated build | singleton authority pointer | 007/011 migrations | authority.test.ts | authority pointer integrity | PASS |
| RBAC incomplete | P1 | roles lacked complete grants | explicit roles/revokes/grants | 009_zsl3_guards_rbac.sql | sql-static.test.ts | rbac_verified | PASS |
