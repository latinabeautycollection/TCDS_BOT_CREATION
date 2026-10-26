-- Non-destructive rollback: revoke V1.4 authority, preserve evidence/history.
BEGIN;
UPDATE zsl.zsl5_authority_state s SET build_run_id=NULL,certification_run_id=NULL,activated_event_id=NULL,updated_at=now() WHERE singleton AND EXISTS(SELECT 1 FROM zsl.zsl5_build_runs b WHERE b.build_run_id=s.build_run_id AND b.engine_version='zsl5-v1.4.0');
UPDATE zsl.zsl5_certification_runs SET status='REVOKED' WHERE engine_version='zsl5-v1.4.0' AND status='CERTIFIED';
UPDATE zsl_tax_acq.national_publication_runs SET status='REVOKED' WHERE status='CERTIFIED';
COMMIT;
