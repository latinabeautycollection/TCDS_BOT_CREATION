# ZSL3 V2.2 Final Remediation Map

| ID | Severity | Original defect | Remediation | Primary proof |
|---|---|---|---|---|
| 1 | P0 | ACS metadata read from raw records | Metadata now comes from exact bound ZSL1 `schema_validation_runs.validation_document.evidence.variableMetadata` and is SHA-bound | `src/metadata/acs-metadata.service.ts`; adversarial metadata test |
| 2 | P0 | Required certification checks hard-coded PASS | Runtime checks are measured and attempt-scoped; unavailable QA evidence becomes `NOT_EXECUTED` | `src/certification/certification.service.ts`, migration 007 |
| 3 | P0 | ZSL2 package SHA not verified | Active bound ZSL2 normalization package SHA and engine version queried and compared | `exact_zsl2_package` check |
| 4 | P0 | Percentile replay reused stored value | Cohort, rank, vintage, geography, and minimum sample are recomputed | `src/replay/replay.service.ts` |
| 5 | P0 | Confidence replay compared duplicate stored values | Confidence is recomputed from persisted evidence and the SHA-bound confidence policy | replay + confidence service |
| 6 | P0 | Derived freshness used first source vintage | Derived freshness uses recursive lineage and worst mandatory input | freshness + lineage services |
| 7 | P0 | Source coverage used fixed divisor | Geography-aware required-source matrix and explicit numerator/denominator | coverage service |
| 8 | P0 | Feature coverage mixed facts/derived | Separate source-fact and derived-feature coverage | snapshot schema + coverage service |
| 9 | P0 | Location coverage hard-coded 100 | Active certified ZSL2 location universe is the denominator | coverage service |
| 10 | P0 | Snapshot source vintage set empty | Exact contributing release roles/vintages stored and hashed | snapshot service |
| 11 | P1 | ACS semantic check only counted rows | Variable-by-variable label/concept/predicate/vintage contract | metadata + certification |
| 12 | P1 | CBP/ZBP vintage/NAICS coherence incomplete | Full dataset-year and NAICS checks | certification/validation |
| 13 | P1 | BEA MSA unresolved rows silently dropped | Every row receives a reconciliation disposition | `zsl3_bea_msa_reconciliation` |
| 14 | P1 | VALIDATING lifecycle stage was empty | Dedicated validation service blocks derivation on P0 defects | validation service |
| 15 | P1 | Runtime checks unique per build only | Immutable `runtime_check_run_id` attempts bind each certification | migration 007/010 |

The V2.2 package preserves ZSL1 acquisition ownership, ZSL2 canonical-geography ownership, and R/ARB/Warehouse boundaries.
