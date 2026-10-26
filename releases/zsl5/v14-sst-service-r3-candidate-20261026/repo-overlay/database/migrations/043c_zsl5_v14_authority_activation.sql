-- TCDS 043c: V1.4 fail-closed activation
BEGIN;
CREATE OR REPLACE FUNCTION zsl.zsl5_activate_v14(p_build uuid,p_cert uuid,p_actor text,p_evidence jsonb) RETURNS uuid LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,zsl,zsl_tax_acq,extensions AS $$
DECLARE c zsl.zsl5_certification_runs%ROWTYPE;r zsl.zsl5_runtime_check_runs%ROWTYPE;b zsl.zsl5_build_runs%ROWTYPE;ev uuid;doc jsonb;
BEGIN
 PERFORM pg_advisory_xact_lock(hashtextextended('TCDS:ZSL5:ACTIVATE',0));
 SELECT * INTO b FROM zsl.zsl5_build_runs WHERE build_run_id=p_build FOR UPDATE; IF b.build_run_id IS NULL OR b.engine_version<>'zsl5-v1.4.0' OR b.state<>'RECONCILED' THEN RAISE EXCEPTION 'ZSL5_V14_BUILD_NOT_RECONCILED'; END IF;
 SELECT * INTO c FROM zsl.zsl5_certification_runs WHERE certification_run_id=p_cert AND build_run_id=p_build AND engine_version='zsl5-v1.4.0' AND status='CERTIFIED'; IF c.certification_run_id IS NULL THEN RAISE EXCEPTION 'ZSL5_V14_CERTIFICATION_NOT_CERTIFIED'; END IF;
 SELECT * INTO r FROM zsl.zsl5_runtime_check_runs WHERE runtime_check_run_id=c.runtime_check_run_id AND build_run_id=p_build AND status='PASS'; IF r.runtime_check_run_id IS NULL THEN RAISE EXCEPTION 'ZSL5_V14_RUNTIME_CHECKS_NOT_PASS'; END IF;
 IF NOT zsl.zsl5_bindings_still_valid(p_build) THEN RAISE EXCEPTION 'ZSL5_V14_BINDINGS_INVALID'; END IF;
 IF EXISTS(SELECT 1 FROM zsl.zsl5_conflicts WHERE build_run_id=p_build AND severity='FATAL') THEN RAISE EXCEPTION 'ZSL5_V14_FATAL_CONFLICT'; END IF;
 IF NOT EXISTS(SELECT 1 FROM zsl.zsl5_v14_national_gate WHERE build_run_id=p_build AND publication_status='CERTIFIED' AND family_certified=1071 AND local_certified=51 AND resolution_certified=51 AND fatal_conflicts=0 AND bindings_valid) THEN RAISE EXCEPTION 'ZSL5_V14_NATIONAL_GATE_NOT_PASS'; END IF;
 ev:=gen_random_uuid();doc:=jsonb_build_object('eventType','ACTIVATED','buildRunId',p_build,'certificationRunId',p_cert,'runtimeCheckRunId',c.runtime_check_run_id,'actor',p_actor,'evidence',p_evidence);
 INSERT INTO zsl.zsl5_authority_events(authority_event_id,build_run_id,certification_run_id,event_type,evidence_document,evidence_sha256) VALUES(ev,p_build,p_cert,'ACTIVATED',doc,encode(extensions.digest(convert_to(doc::text,'UTF8'),'sha256'),'hex'));
 UPDATE zsl.zsl5_authority_state SET build_run_id=p_build,certification_run_id=p_cert,activated_event_id=ev,updated_at=now() WHERE singleton; RETURN ev;
END $$;
COMMIT;
