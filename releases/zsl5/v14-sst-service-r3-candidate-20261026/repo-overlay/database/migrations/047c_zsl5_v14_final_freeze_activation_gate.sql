-- TCDS 047c: final-freeze activation/readiness gate
BEGIN;
CREATE OR REPLACE VIEW zsl.zsl5_v14_final_freeze_gate AS
SELECT g.*,
       NOT EXISTS(SELECT 1 FROM zsl.zsl5_v14_payload_contract_violations v WHERE v.build_run_id=g.build_run_id) AS payload_contract_valid
FROM zsl.zsl5_v14_runtime_authority_gate g
JOIN zsl.zsl5_national_publication_bindings_v14 nb ON nb.build_run_id=g.build_run_id
LEFT JOIN zsl_tax_acq.v_publication_freshness_readiness f ON f.publication_id=nb.publication_id
CROSS JOIN zsl_tax_acq.v_tax_security_posture s;

CREATE OR REPLACE FUNCTION zsl.zsl5_activate_v14(p_build uuid,p_cert uuid,p_actor text,p_evidence jsonb) RETURNS uuid
LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,zsl,zsl_tax_acq,extensions AS $$
DECLARE c zsl.zsl5_certification_runs%ROWTYPE;r zsl.zsl5_runtime_check_runs%ROWTYPE;b zsl.zsl5_build_runs%ROWTYPE;ev uuid;doc jsonb;g record;
BEGIN
 IF NOT pg_has_role(session_user,'zsl5_admin','member') AND session_user<>'postgres' THEN RAISE EXCEPTION 'ZSL5_ADMIN_ROLE_REQUIRED'; END IF;
 PERFORM pg_advisory_xact_lock(hashtextextended('TCDS:ZSL5:ACTIVATE',0));
 SELECT * INTO b FROM zsl.zsl5_build_runs WHERE build_run_id=p_build FOR UPDATE; IF b.build_run_id IS NULL OR b.engine_version<>'zsl5-v1.4.0' OR b.state<>'RECONCILED' THEN RAISE EXCEPTION 'ZSL5_V14_BUILD_NOT_RECONCILED'; END IF;
 SELECT * INTO c FROM zsl.zsl5_certification_runs WHERE certification_run_id=p_cert AND build_run_id=p_build AND engine_version='zsl5-v1.4.0' AND status='CERTIFIED'; IF c.certification_run_id IS NULL THEN RAISE EXCEPTION 'ZSL5_V14_CERTIFICATION_NOT_CERTIFIED'; END IF;
 SELECT * INTO r FROM zsl.zsl5_runtime_check_runs WHERE runtime_check_run_id=c.runtime_check_run_id AND build_run_id=p_build AND status='PASS'; IF r.runtime_check_run_id IS NULL THEN RAISE EXCEPTION 'ZSL5_V14_RUNTIME_CHECKS_NOT_PASS'; END IF;
 SELECT * INTO g FROM zsl.zsl5_v14_final_freeze_gate WHERE build_run_id=p_build; IF g.build_run_id IS NULL THEN RAISE EXCEPTION 'ZSL5_V14_FREEZE_GATE_MISSING'; END IF;
 IF NOT g.bindings_valid OR g.publication_status<>'CERTIFIED' OR g.family_certified<>1071 OR g.local_certified<>51 OR g.resolution_certified<>51 OR g.fatal_conflicts<>0 OR NOT g.payload_contract_valid OR NOT g.freshness_ready OR NOT g.security_ready OR g.required_category_count<>10 OR g.mapped_category_count<>10 OR g.golden_states_passed<>51 OR g.golden_failures<>0 OR g.golden_not_executed<>0 OR g.adversarial_failures<>0 OR g.adversarial_not_executed<>0 THEN RAISE EXCEPTION 'ZSL5_V14_FINAL_FREEZE_GATE_NOT_PASS'; END IF;
 ev:=gen_random_uuid();doc:=jsonb_build_object('eventType','ACTIVATED','buildRunId',p_build,'certificationRunId',p_cert,'runtimeCheckRunId',c.runtime_check_run_id,'actor',p_actor,'freezeGate','V1.2.0','evidence',p_evidence);
 INSERT INTO zsl.zsl5_authority_events(authority_event_id,build_run_id,certification_run_id,event_type,evidence_document,evidence_sha256) VALUES(ev,p_build,p_cert,'ACTIVATED',doc,encode(extensions.digest(convert_to(doc::text,'UTF8'),'sha256'),'hex'));
 UPDATE zsl.zsl5_authority_state SET build_run_id=p_build,certification_run_id=p_cert,activated_event_id=ev,updated_at=now() WHERE singleton;RETURN ev;
END $$;
REVOKE ALL ON FUNCTION zsl.zsl5_activate_v14(uuid,uuid,text,jsonb) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION zsl.zsl5_activate_v14(uuid,uuid,text,jsonb) TO zsl5_admin;
COMMIT;
