-- TCDS 046b: dynamic freshness, category, security, and activation validation
BEGIN;

DO $$ BEGIN
 IF NOT EXISTS(SELECT 1 FROM pg_roles WHERE rolname='zsl5_activator') THEN CREATE ROLE zsl5_activator NOLOGIN; END IF;
END $$;
GRANT USAGE ON SCHEMA zsl,zsl_tax_acq TO zsl5_activator;
CREATE OR REPLACE VIEW zsl.zsl5_v14_runtime_authority_gate AS
SELECT b.build_run_id,g.publication_id,g.publication_status,g.family_certified,g.local_certified,g.resolution_certified,g.fatal_conflicts,
 (select count(*)::int from zsl.zsl5_source_bindings sb where sb.build_run_id=b.build_run_id) source_binding_count,g.bindings_valid,
 rr.golden_states_passed,rr.golden_failures,rr.golden_not_executed,rr.adversarial_failures,rr.adversarial_not_executed,
 (g.publication_status='CERTIFIED' AND g.family_certified=1071 AND g.local_certified=51 AND g.resolution_certified=51 AND g.fatal_conflicts=0
  AND (select count(*) from zsl.zsl5_source_bindings sb where sb.build_run_id=b.build_run_id)=21 AND g.bindings_valid
  AND coalesce(rr.ready,false)
  AND (select count(distinct m.tcds_category_code) from zsl.zsl5_tax_product_mappings_v14 m join zsl.zsl5_required_tcds_categories_v14 rc using(tcds_category_code) where m.build_run_id=b.build_run_id and m.enabled and rc.enabled)=10
  AND coalesce(fr.ready,false) AND coalesce(sec.no_public_mutation,false)) AS ready,
 (select count(*)::int from zsl.zsl5_required_tcds_categories_v14 rc where rc.enabled) required_category_count,
 (select count(distinct m.tcds_category_code)::int from zsl.zsl5_tax_product_mappings_v14 m join zsl.zsl5_required_tcds_categories_v14 rc using(tcds_category_code) where m.build_run_id=b.build_run_id and m.enabled and rc.enabled) mapped_category_count,
 coalesce(fr.ready,false) freshness_ready,
 coalesce(sec.no_public_mutation,false) security_ready

FROM zsl.zsl5_build_runs b
JOIN zsl.zsl5_v14_national_gate g ON g.build_run_id=b.build_run_id
LEFT JOIN zsl_tax_acq.v_runtime_certification_readiness rr ON rr.build_run_id=b.build_run_id
LEFT JOIN zsl.zsl5_national_publication_bindings_v14 np ON np.build_run_id=b.build_run_id
LEFT JOIN zsl_tax_acq.v_publication_freshness_readiness fr ON fr.publication_id=np.publication_id
CROSS JOIN zsl_tax_acq.v_tax_security_posture sec
WHERE b.engine_version='zsl5-v1.4.0';

CREATE OR REPLACE FUNCTION zsl.zsl5_v14_runtime_ready(p_build uuid) RETURNS boolean
LANGUAGE sql STABLE SECURITY DEFINER SET search_path=pg_catalog,zsl,zsl_tax_acq AS $$
 SELECT coalesce((SELECT ready FROM zsl.zsl5_v14_runtime_authority_gate WHERE build_run_id=p_build),false)
$$;

-- Current bindings must also point at a fresh publication and still-current ZSL2 authority.
CREATE OR REPLACE FUNCTION zsl.zsl5_bindings_still_valid(p_build uuid) RETURNS boolean
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path=pg_catalog,zsl,zsl_tax_acq AS $$
DECLARE v_engine text; v_pub uuid;
BEGIN
 SELECT engine_version INTO v_engine FROM zsl.zsl5_build_runs WHERE build_run_id=p_build;
 IF v_engine IS NULL THEN RETURN false; END IF;
 IF v_engine='zsl5-v1.2.0' THEN
  RETURN NOT EXISTS(SELECT 1 FROM zsl.zsl5_source_bindings b WHERE b.build_run_id=p_build AND NOT EXISTS(SELECT 1 FROM LATERAL(SELECT c.* FROM zsl.certification_runs c WHERE c.ingest_run_id=b.ingest_run_id ORDER BY c.created_at DESC,c.certification_run_id DESC LIMIT 1) x WHERE x.certification_run_id=b.certification_run_id AND x.status='CERTIFIED'))
  AND EXISTS(SELECT 1 FROM zsl.zsl5_zsl2_bindings b JOIN zsl.zsl2_current_authority a ON a.normalization_run_id=b.zsl2_normalization_run_id AND a.certification_run_id=b.zsl2_certification_run_id WHERE b.build_run_id=p_build);
 END IF;
 IF v_engine<>'zsl5-v1.4.0' THEN RETURN false; END IF;
 SELECT publication_id INTO v_pub FROM zsl.zsl5_national_publication_bindings_v14 WHERE build_run_id=p_build;
 IF v_pub IS NULL THEN RETURN false; END IF;
 IF NOT EXISTS(SELECT 1 FROM zsl_tax_acq.national_publication_runs p JOIN zsl_tax_acq.v_publication_freshness_readiness f USING(publication_id) WHERE p.publication_id=v_pub AND p.status='CERTIFIED' AND p.family_certified=1071 AND p.local_certified=51 AND p.resolution_certified=51 AND p.fatal_conflicts=0 AND p.certification_run_id IS NOT NULL AND f.ready) THEN RETURN false; END IF;
 IF (SELECT count(*) FROM zsl.zsl5_source_bindings WHERE build_run_id=p_build)<>21 OR (SELECT count(DISTINCT source_role) FROM zsl.zsl5_source_bindings WHERE build_run_id=p_build)<>21 THEN RETURN false; END IF;
 IF EXISTS(SELECT f.family FROM zsl_tax_acq.family_registry f WHERE f.enabled AND NOT EXISTS(SELECT 1 FROM zsl.zsl5_source_bindings b WHERE b.build_run_id=p_build AND b.source_role=f.family)) THEN RETURN false; END IF;
 IF EXISTS(SELECT 1 FROM zsl.zsl5_source_bindings b JOIN zsl.source_releases r ON r.release_id=b.release_id JOIN zsl.ingest_runs i ON i.ingest_run_id=b.ingest_run_id JOIN zsl.certification_runs c ON c.certification_run_id=b.certification_run_id LEFT JOIN zsl.schema_validation_runs s ON s.schema_validation_run_id=b.schema_validation_run_id WHERE b.build_run_id=p_build AND (r.status<>'RECONCILED' OR i.state<>'RECONCILED' OR i.parser_replay_pass IS DISTINCT FROM true OR c.status<>'CERTIFIED' OR b.schema_validation_run_id IS NULL OR s.status<>'PASS')) THEN RETURN false; END IF;
 IF EXISTS(SELECT 1 FROM zsl.zsl5_source_bindings b WHERE b.build_run_id=p_build AND NOT EXISTS(SELECT 1 FROM zsl.reconciliation_runs q WHERE q.ingest_run_id=b.ingest_run_id AND q.parser_replay_pass=true)) THEN RETURN false; END IF;
 IF NOT EXISTS(SELECT 1 FROM zsl.zsl5_zsl2_bindings b JOIN zsl.zsl2_current_authority a ON a.normalization_run_id=b.zsl2_normalization_run_id AND a.certification_run_id=b.zsl2_certification_run_id WHERE b.build_run_id=p_build) THEN RETURN false; END IF;
 RETURN true;
END $$;

REVOKE ALL ON FUNCTION zsl.zsl5_v14_runtime_ready(uuid) FROM PUBLIC;
REVOKE ALL ON FUNCTION zsl.zsl5_bindings_still_valid(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION zsl.zsl5_v14_runtime_ready(uuid),zsl.zsl5_bindings_still_valid(uuid) TO zsl5_reader,zsl5_builder,zsl5_certifier,zsl5_admin;

REVOKE ALL ON FUNCTION zsl.zsl5_activate_v14(uuid,uuid,text,jsonb) FROM PUBLIC;
REVOKE ALL ON FUNCTION zsl_tax_acq.refresh_state_runtime_readiness(character) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION zsl.zsl5_activate_v14(uuid,uuid,text,jsonb) TO zsl5_activator,zsl5_admin;
GRANT EXECUTE ON FUNCTION zsl_tax_acq.refresh_state_runtime_readiness(character) TO zsl_tax_acq_certifier,zsl_tax_acq_normalizer;

COMMIT;
