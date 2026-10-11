BEGIN;
DROP VIEW IF EXISTS zsl.certified_release_records;
DROP TRIGGER IF EXISTS trg_memberships_immutable ON zsl.release_record_memberships;
DROP TRIGGER IF EXISTS trg_raw_records_immutable ON zsl_raw.raw_records;
DROP TRIGGER IF EXISTS trg_artifacts_immutable ON zsl.source_artifacts;
-- Non-destructive rollback: runtime views/functions/triggers are removed.
-- Historical evidence tables are intentionally retained.
COMMIT;
