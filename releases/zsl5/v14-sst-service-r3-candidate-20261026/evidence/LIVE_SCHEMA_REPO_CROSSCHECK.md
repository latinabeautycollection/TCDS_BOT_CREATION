# Live schema / repository cross-check

Validated on 2026-10-26 against the connected staging ZSL project and GitHub repository `latinabeautycollection/TCDS_BOT_CREATION`.

## GitHub baseline
- default branch: `main`
- observed head: `ef985e28f41a56b5b5d25252aacdb1ab456888b0`
- observed latest message: `Isolate ZSL governance trigger row types`
- existing committed ZSL migrations end at `040_zsl_pgcrypto_schema_qualification.sql` and `041_zsl_governance_trigger_row_isolation.sql`
- no existing migration names beginning `042` or `043`
- no existing `apps/zsl-tax-intelligence` code path
- root TypeScript config compiles `apps/**/*.ts`
- root repo already contains `pg`, TypeScript, tsx, ESM, ES2022-compatible configuration

## Deployed ZSL contracts confirmed
- `zsl_raw.raw_records(record_id uuid, record_sha256 text UNIQUE, natural_key text, record jsonb, created_at timestamptz)`
- `zsl.release_record_memberships.record_id` references `zsl_raw.raw_records(record_id)`
- ZSL1 source/release/ingest/artifact/schema-validation/reconciliation/certification tables exist
- ZSL5 V1.2 build and certification tables currently constrain `engine_version = 'zsl5-v1.2.0'`
- deployed ZSL5 authority state/current-authority surfaces exist
- deployed `zsl.zsl5_bindings_still_valid(uuid)` only checks latest certification and current ZSL2 authority; V1.4 migration replaces it additively with stronger checks while preserving a V1.2 compatibility branch

## Boundary alignment
- no Retail/R1A mutation
- no R1F mutation
- no ARB mutation
- no PQP/CAX mutation
- ZSL1 remains source authority
- ZSL2 remains geographic identity authority
- ZSL5 remains tax/government acquisition-cost determination authority
