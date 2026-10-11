BEGIN;
SET LOCAL search_path=pg_catalog,zsl,public,extensions;

CREATE OR REPLACE FUNCTION zsl.zsl2_activate(p_run uuid,p_cert uuid,p_actor text,p_reason text,p_evidence jsonb,p_evidence_sha text)
RETURNS uuid LANGUAGE plpgsql VOLATILE SECURITY DEFINER SET search_path=pg_catalog,zsl AS $$
DECLARE c record; eid uuid; id uuid; bad bigint;
BEGIN
 PERFORM pg_advisory_xact_lock(hashtextextended('TCDS:ZSL2:ACTIVATE',0));
 SELECT * INTO c FROM zsl.zsl2_certification_runs WHERE certification_run_id=p_cert AND normalization_run_id=p_run;
 IF c.certification_run_id IS NULL OR c.status<>'CERTIFIED' THEN RAISE EXCEPTION 'ZSL2_V214_ACTIVATE_REQUIRES_CERTIFIED'; END IF;
 IF NOT zsl.zsl2_zsl1_authority_decision_current_v214(p_run) THEN RAISE EXCEPTION 'ZSL2_V214_ACTIVATE_ZSL1_AUTHORITY_INVALID'; END IF;
 eid:=nullif(c.evidence->>'evaluation_id','')::uuid;
 IF eid IS NULL THEN RAISE EXCEPTION 'ZSL2_V214_ACTIVATE_EVALUATION_REQUIRED'; END IF;
 SELECT count(*) INTO bad FROM (values
  ('postgres_performance_runtime_pass'),('rbac_runtime_pass'),('activation_runtime_pass'),('rollback_runtime_pass'),('deterministic_replay'),('page_performance_observed'),('territorial_pending_evidence_valid'),('zsl1_authority_decision_valid')
 ) v(name) WHERE NOT EXISTS(SELECT 1 FROM zsl.zsl2_runtime_checks_v214 r WHERE r.evaluation_id=eid AND r.normalization_run_id=p_run AND r.check_name=v.name AND r.passed);
 IF bad<>0 THEN RAISE EXCEPTION 'ZSL2_V214_ACTIVATE_REQUIRED_CHECKS_MISSING:%',bad; END IF;
 IF EXISTS(SELECT 1 FROM zsl.zsl2_conflicts WHERE normalization_run_id=p_run AND severity='FATAL' AND NOT resolved) THEN RAISE EXCEPTION 'ZSL2_V214_ACTIVATE_FATAL_CONFLICTS'; END IF;
 INSERT INTO zsl.zsl2_authority_events(normalization_run_id,certification_run_id,event_type,actor_id,reason,evidence,evidence_sha256)
 VALUES(p_run,p_cert,'ACTIVATED',p_actor,p_reason,p_evidence,p_evidence_sha) RETURNING authority_event_id INTO id;
 RETURN id;
END $$;

CREATE OR REPLACE FUNCTION zsl.zsl2_revoke(p_run uuid,p_cert uuid,p_actor text,p_reason text,p_evidence jsonb,p_evidence_sha text)
RETURNS uuid LANGUAGE plpgsql VOLATILE SECURITY DEFINER SET search_path=pg_catalog,zsl AS $$
DECLARE id uuid;
BEGIN
 PERFORM pg_advisory_xact_lock(hashtextextended('TCDS:ZSL2:ACTIVATE',0));
 IF NOT EXISTS(SELECT 1 FROM zsl.zsl2_current_authority WHERE normalization_run_id=p_run AND certification_run_id=p_cert) THEN RAISE EXCEPTION 'ZSL2_V214_REVOKE_REQUIRES_CURRENT_AUTHORITY'; END IF;
 INSERT INTO zsl.zsl2_authority_events(normalization_run_id,certification_run_id,event_type,actor_id,reason,evidence,evidence_sha256)
 VALUES(p_run,p_cert,'REVOKED',p_actor,p_reason,p_evidence,p_evidence_sha) RETURNING authority_event_id INTO id;
 RETURN id;
END $$;

REVOKE EXECUTE ON FUNCTION zsl.zsl2_activate(uuid,uuid,text,text,jsonb,text),zsl.zsl2_revoke(uuid,uuid,text,text,jsonb,text) FROM PUBLIC;
DO $$ BEGIN
 IF EXISTS(SELECT 1 FROM pg_roles WHERE rolname='zsl2_certifier') THEN GRANT EXECUTE ON FUNCTION zsl.zsl2_activate(uuid,uuid,text,text,jsonb,text),zsl.zsl2_revoke(uuid,uuid,text,text,jsonb,text) TO zsl2_certifier; END IF;
END $$;
COMMIT;
