BEGIN;
DROP VIEW IF EXISTS zsl.current_geographic_economic_features;
DROP VIEW IF EXISTS zsl.zsl3_current_authority;
REVOKE EXECUTE ON FUNCTION zsl.zsl3_activate(uuid,uuid,text,jsonb) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION zsl.zsl3_revoke_active(text,jsonb) FROM PUBLIC;
UPDATE zsl.zsl3_authority_state SET build_run_id=NULL,certification_run_id=NULL,updated_at=now() WHERE singleton;
COMMIT;
-- Historical facts, lineage, snapshots, checks, certifications, and authority events are intentionally preserved.
