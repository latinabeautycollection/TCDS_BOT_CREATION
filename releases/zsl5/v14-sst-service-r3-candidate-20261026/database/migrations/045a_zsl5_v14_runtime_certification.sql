BEGIN;
CREATE OR REPLACE VIEW zsl.zsl5_v14_runtime_authority_gate AS
SELECT b.build_run_id,g.publication_id,g.publication_status,g.family_certified,g.local_certified,g.resolution_certified,g.fatal_conflicts,(select count(*)::int from zsl.zsl5_source_bindings sb where sb.build_run_id=b.build_run_id) source_binding_count,g.bindings_valid,
 rr.golden_states_passed,rr.golden_failures,rr.golden_not_executed,rr.adversarial_failures,rr.adversarial_not_executed,
 (g.publication_status='CERTIFIED' AND g.family_certified=1071 AND g.local_certified=51 AND g.resolution_certified=51 AND g.fatal_conflicts=0 AND (select count(*) from zsl.zsl5_source_bindings sb where sb.build_run_id=b.build_run_id)=21 AND g.bindings_valid AND coalesce(rr.ready,false)) AS ready
FROM zsl.zsl5_build_runs b
JOIN zsl.zsl5_v14_national_gate g ON g.build_run_id=b.build_run_id
LEFT JOIN zsl_tax_acq.v_runtime_certification_readiness rr ON rr.build_run_id=b.build_run_id
WHERE b.engine_version='zsl5-v1.4.0';

CREATE OR REPLACE FUNCTION zsl.zsl5_v14_runtime_ready(p_build uuid) RETURNS boolean
LANGUAGE sql STABLE SECURITY DEFINER SET search_path=pg_catalog,zsl,zsl_tax_acq AS $$
 SELECT coalesce((SELECT ready FROM zsl.zsl5_v14_runtime_authority_gate WHERE build_run_id=p_build),false)
$$;

-- Binding validity is intentionally independent from runtime certification so candidate builds can be tested before activation.
CREATE OR REPLACE FUNCTION zsl.zsl5_bindings_still_valid(p_build uuid) RETURNS boolean
LANGUAGE sql STABLE SECURITY DEFINER SET search_path=zsl,pg_catalog,zsl_tax_acq AS $$
 SELECT
 NOT EXISTS(
   SELECT 1 FROM zsl.zsl5_source_bindings b
   WHERE b.build_run_id=p_build AND NOT EXISTS(
     SELECT 1 FROM zsl.certification_runs c
     JOIN zsl.ingest_runs i ON i.ingest_run_id=c.ingest_run_id
     JOIN zsl.source_releases r ON r.release_id=i.release_id
     LEFT JOIN zsl.schema_validation_runs sv ON sv.schema_validation_run_id=b.schema_validation_run_id
     WHERE c.certification_run_id=b.certification_run_id AND c.ingest_run_id=b.ingest_run_id AND c.status='CERTIFIED'
       AND r.release_id=b.release_id AND r.status='RECONCILED'
       AND (b.schema_validation_run_id IS NULL OR sv.status='PASS')
   )
 )
 AND EXISTS(SELECT 1 FROM zsl.zsl5_zsl2_bindings b JOIN zsl.zsl2_current_authority a ON a.normalization_run_id=b.zsl2_normalization_run_id AND a.certification_run_id=b.zsl2_certification_run_id WHERE b.build_run_id=p_build);
$$;

CREATE OR REPLACE FUNCTION zsl.zsl5_activate_v14(p_build uuid,p_cert uuid,p_actor text,p_evidence jsonb) RETURNS uuid LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,zsl,zsl_tax_acq,extensions AS $$
DECLARE c zsl.zsl5_certification_runs%ROWTYPE;r zsl.zsl5_runtime_check_runs%ROWTYPE;b zsl.zsl5_build_runs%ROWTYPE;ev uuid;doc jsonb;
BEGIN
 PERFORM pg_advisory_xact_lock(hashtextextended('TCDS:ZSL5:ACTIVATE',0));
 SELECT * INTO b FROM zsl.zsl5_build_runs WHERE build_run_id=p_build FOR UPDATE; IF b.build_run_id IS NULL OR b.engine_version<>'zsl5-v1.4.0' OR b.state<>'RECONCILED' THEN RAISE EXCEPTION 'ZSL5_V14_BUILD_NOT_RECONCILED'; END IF;
 SELECT * INTO c FROM zsl.zsl5_certification_runs WHERE certification_run_id=p_cert AND build_run_id=p_build AND engine_version='zsl5-v1.4.0' AND status='CERTIFIED'; IF c.certification_run_id IS NULL THEN RAISE EXCEPTION 'ZSL5_V14_CERTIFICATION_NOT_CERTIFIED'; END IF;
 SELECT * INTO r FROM zsl.zsl5_runtime_check_runs WHERE runtime_check_run_id=c.runtime_check_run_id AND build_run_id=p_build AND status='PASS'; IF r.runtime_check_run_id IS NULL THEN RAISE EXCEPTION 'ZSL5_V14_RUNTIME_CHECKS_NOT_PASS'; END IF;
 IF NOT zsl.zsl5_bindings_still_valid(p_build) THEN RAISE EXCEPTION 'ZSL5_V14_BINDINGS_INVALID'; END IF;
 IF NOT zsl.zsl5_v14_runtime_ready(p_build) THEN RAISE EXCEPTION 'ZSL5_V14_RUNTIME_AUTHORITY_GATE_NOT_PASS'; END IF;
 IF EXISTS(SELECT 1 FROM zsl.zsl5_conflicts WHERE build_run_id=p_build AND severity='FATAL') THEN RAISE EXCEPTION 'ZSL5_V14_FATAL_CONFLICT'; END IF;
 ev:=gen_random_uuid();doc:=jsonb_build_object('eventType','ACTIVATED','buildRunId',p_build,'certificationRunId',p_cert,'runtimeCheckRunId',c.runtime_check_run_id,'actor',p_actor,'evidence',p_evidence);
 INSERT INTO zsl.zsl5_authority_events(authority_event_id,build_run_id,certification_run_id,event_type,evidence_document,evidence_sha256) VALUES(ev,p_build,p_cert,'ACTIVATED',doc,encode(extensions.digest(convert_to(doc::text,'UTF8'),'sha256'),'hex'));
 UPDATE zsl.zsl5_authority_state SET build_run_id=p_build,certification_run_id=p_cert,activated_event_id=ev,updated_at=now() WHERE singleton; RETURN ev;
END $$;
COMMIT;
