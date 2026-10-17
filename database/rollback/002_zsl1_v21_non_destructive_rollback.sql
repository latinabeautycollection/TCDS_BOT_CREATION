BEGIN;
-- V2.1 non-destructive rollback removes runtime authority surfaces and guards
-- introduced by migration 002 while retaining all historical evidence/data.
DROP VIEW IF EXISTS zsl.certified_release_records;
DROP TRIGGER IF EXISTS trg_certification_insert_guard ON zsl.certification_runs;
DROP TRIGGER IF EXISTS trg_certified_release_immutable ON zsl.source_releases;
DROP TRIGGER IF EXISTS trg_source_policy_content_immutable ON zsl.source_policies;
DROP TRIGGER IF EXISTS trg_schema_contract_content_immutable ON zsl.schema_contracts;
DROP TRIGGER IF EXISTS trg_cert_policy_content_immutable ON zsl.certification_policies;
DROP TRIGGER IF EXISTS trg_audit_immutable ON zsl.ingest_audit_events;
DROP TRIGGER IF EXISTS trg_schema_validation_immutable ON zsl.schema_validation_runs;
DROP TRIGGER IF EXISTS trg_reconciliation_immutable ON zsl.reconciliation_runs;
DROP TRIGGER IF EXISTS trg_certification_immutable ON zsl.certification_runs;
DROP FUNCTION IF EXISTS zsl.certification_insert_guard();
DROP FUNCTION IF EXISTS zsl.prevent_certified_release_mutation();
DROP FUNCTION IF EXISTS zsl.prevent_governance_content_mutation();
DROP FUNCTION IF EXISTS zsl.append_ingest_audit_event(uuid,text,text,jsonb);
-- Do not drop reconciliation/evidence tables or V2.1 columns. Retaining them keeps
-- the forensic chain available for investigation and a later forward migration.
COMMIT;
