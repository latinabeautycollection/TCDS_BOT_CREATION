-- TCDS 043b: Strict national publication binding and coverage validity
BEGIN;
CREATE OR REPLACE FUNCTION zsl.zsl5_bindings_still_valid(p_build uuid) RETURNS boolean LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path=pg_catalog,zsl,zsl_tax_acq AS $$
DECLARE v_engine text;v_pub uuid;
BEGIN
 SELECT engine_version INTO v_engine FROM zsl.zsl5_build_runs WHERE build_run_id=p_build; IF v_engine IS NULL THEN RETURN false; END IF;
 IF v_engine='zsl5-v1.2.0' THEN
  RETURN NOT EXISTS(SELECT 1 FROM zsl.zsl5_source_bindings b WHERE b.build_run_id=p_build AND NOT EXISTS(SELECT 1 FROM LATERAL(SELECT c.* FROM zsl.certification_runs c WHERE c.ingest_run_id=b.ingest_run_id ORDER BY c.created_at DESC,c.certification_run_id DESC LIMIT 1) x WHERE x.certification_run_id=b.certification_run_id AND x.status='CERTIFIED'))
  AND EXISTS(SELECT 1 FROM zsl.zsl5_zsl2_bindings b JOIN zsl.zsl2_current_authority a ON a.normalization_run_id=b.zsl2_normalization_run_id AND a.certification_run_id=b.zsl2_certification_run_id WHERE b.build_run_id=p_build);
 END IF;
 IF v_engine<>'zsl5-v1.4.0' THEN RETURN false; END IF;
 SELECT publication_id INTO v_pub FROM zsl.zsl5_national_publication_bindings_v14 WHERE build_run_id=p_build; IF v_pub IS NULL THEN RETURN false; END IF;
 IF NOT EXISTS(SELECT 1 FROM zsl_tax_acq.national_publication_runs p WHERE p.publication_id=v_pub AND p.status='CERTIFIED' AND p.family_certified=1071 AND p.local_certified=51 AND p.resolution_certified=51 AND p.fatal_conflicts=0 AND p.certification_run_id IS NOT NULL) THEN RETURN false; END IF;
 IF (SELECT count(*) FROM zsl.zsl5_source_bindings WHERE build_run_id=p_build)<>21 OR (SELECT count(DISTINCT source_role) FROM zsl.zsl5_source_bindings WHERE build_run_id=p_build)<>21 THEN RETURN false; END IF;
 IF EXISTS(SELECT f.family FROM zsl_tax_acq.family_registry f WHERE f.enabled AND NOT EXISTS(SELECT 1 FROM zsl.zsl5_source_bindings b WHERE b.build_run_id=p_build AND b.source_role=f.family)) THEN RETURN false; END IF;
 IF EXISTS(SELECT 1 FROM zsl.zsl5_source_bindings b JOIN zsl.source_releases r ON r.release_id=b.release_id JOIN zsl.ingest_runs i ON i.ingest_run_id=b.ingest_run_id JOIN zsl.certification_runs c ON c.certification_run_id=b.certification_run_id LEFT JOIN zsl.schema_validation_runs s ON s.schema_validation_run_id=b.schema_validation_run_id WHERE b.build_run_id=p_build AND (r.status<>'RECONCILED' OR i.state<>'RECONCILED' OR i.parser_replay_pass IS DISTINCT FROM true OR c.status<>'CERTIFIED' OR b.schema_validation_run_id IS NULL OR s.status<>'PASS')) THEN RETURN false; END IF;
 IF EXISTS(SELECT 1 FROM zsl.zsl5_source_bindings b WHERE b.build_run_id=p_build AND NOT EXISTS(SELECT 1 FROM zsl.reconciliation_runs q WHERE q.ingest_run_id=b.ingest_run_id AND q.parser_replay_pass=true)) THEN RETURN false; END IF;
 IF NOT EXISTS(SELECT 1 FROM zsl.zsl5_zsl2_bindings b JOIN zsl.zsl2_current_authority a ON a.normalization_run_id=b.zsl2_normalization_run_id AND a.certification_run_id=b.zsl2_certification_run_id WHERE b.build_run_id=p_build) THEN RETURN false; END IF;
 RETURN true;
END $$;

CREATE OR REPLACE VIEW zsl.zsl5_v14_national_gate AS SELECT b.build_run_id,p.publication_id,p.status publication_status,p.family_certified,p.family_expected,p.local_certified,p.local_expected,p.resolution_certified,p.resolution_expected,p.fatal_conflicts,zsl.zsl5_bindings_still_valid(b.build_run_id) bindings_valid FROM zsl.zsl5_national_publication_bindings_v14 b JOIN zsl_tax_acq.national_publication_runs p ON p.publication_id=b.publication_id;
COMMIT;
