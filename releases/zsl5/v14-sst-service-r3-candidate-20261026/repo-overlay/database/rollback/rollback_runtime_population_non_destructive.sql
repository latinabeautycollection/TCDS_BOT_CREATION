BEGIN;
-- Non-destructive rollback: revoke runtime authority first; preserve all evidence/history.
UPDATE zsl.zsl5_certification_runs SET status='REVOKED'
WHERE engine_version='zsl5-v1.4.0' AND status='CERTIFIED';
UPDATE zsl.zsl5_authority_state SET build_run_id=NULL,certification_run_id=NULL,activated_event_id=NULL,updated_at=now()
WHERE singleton AND build_run_id IN (SELECT build_run_id FROM zsl.zsl5_build_runs WHERE engine_version='zsl5-v1.4.0');
-- Runtime tables and acquired evidence are intentionally retained for audit/replay.
COMMIT;
