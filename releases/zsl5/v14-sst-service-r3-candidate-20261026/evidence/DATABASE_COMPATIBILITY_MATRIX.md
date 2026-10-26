# Database Compatibility Matrix — Final Freeze

Cross-checked against the supplied ZSL schema and live staging metadata (`kqcdqtazcqaawdkmcfed`) on 2026-10-26.

| Object / field | Database contract | Application contract | Status / mitigation |
|---|---|---|---|
| `zsl.source_registry.source_id` | `uuid` NOT NULL | string UUID | PASS |
| `zsl.source_releases.release_id` | `uuid` | string UUID | PASS |
| `zsl.ingest_runs.*_count` | `bigint` | DB-side counts / JS numbers only for bounded status output | PASS |
| `zsl.source_artifacts.artifact_id` | `uuid` | string UUID | PASS |
| `zsl.release_record_memberships.record_id` | FK `uuid` → `zsl_raw.raw_records` | string UUID | PASS |
| `zsl_raw.raw_records.record_sha256` | unique text SHA-256 | canonical SHA-256 | PASS; V1.2 no UPDATE-on-conflict |
| `zsl_raw.raw_records.record` | `jsonb` object | canonical JSON object | PASS |
| `zsl.states.usps_code` | `char(2)` | 2-char state code | PASS |
| `zsl.counties.state_fips` | `char(2)` | string | PASS |
| `zsl.postal_codes.postal_code` | `char(5)` | ZIP5 string | PASS; ZIP9 kept outside this table |
| legacy `zsl.zsl5_tax_jurisdictions.state_code` | live metadata confirms `char(2)` | historical V1.2 | PASS; V1.4 does not depend on legacy type |
| `zsl.zsl5_family_facts_v14.state_code` | `char(2)` + final format CHECK | two-letter uppercase string | PASS |
| money fields | `bigint` cents | BigInt internally; safe integer at DB boundary | PASS |
| rate fields | canonical JSON numeric; runtime scaled decimal | string→BigInt scale 12 | PASS |
| legal/effective times | `timestamptz` | explicit ISO instant with offset | PASS |
| canonical intervals | final-freeze requires `effective_to > effective_from` | half-open lookup | PASS |
| quote JSON ledgers | `jsonb` | object/array JSON | PASS |
| `zsl5_check_status` | existing DB enum | migration/runtime use existing PASS/FAIL/NOT_EXECUTED semantics | PASS |
| ZSL6 | absent | read-only future consumer interface only | PASS boundary |

Note: the text-only schema export omitted some typmods in display; live metadata was used where available. No production schema changes were executed during this build.
