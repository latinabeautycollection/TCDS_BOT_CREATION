BEGIN;
SET LOCAL search_path=pg_catalog,zsl,public,extensions;
CREATE OR REPLACE FUNCTION zsl.zsl3_activate(p_build uuid,p_cert uuid,p_actor text,p_evidence jsonb)
RETURNS bigint LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,zsl AS $$
DECLARE ev bigint; c zsl.zsl3_certification_runs%ROWTYPE; evsha text;
BEGIN
 SELECT * INTO c FROM zsl.zsl3_certification_runs WHERE certification_run_id=p_cert AND build_run_id=p_build;
 IF c.certification_run_id IS NULL OR c.status<>'CERTIFIED' THEN RAISE EXCEPTION 'ZSL3_CERTIFICATION_NOT_CERTIFIED'; END IF;
 IF NOT EXISTS(SELECT 1 FROM zsl.zsl3_runtime_check_runs r WHERE r.runtime_check_run_id=c.runtime_check_run_id AND r.build_run_id=p_build AND r.status='PASS') THEN RAISE EXCEPTION 'ZSL3_RUNTIME_CHECK_RUN_NOT_PASSING'; END IF;
 IF NOT zsl.zsl3_bindings_still_valid(p_build) THEN RAISE EXCEPTION 'ZSL3_UPSTREAM_BINDINGS_INVALID'; END IF;
 evsha:=encode(digest(convert_to(jsonb_build_object('eventType','ACTIVATED','buildRunId',p_build,'certificationRunId',p_cert,'runtimeCheckRunId',c.runtime_check_run_id,'actor',p_actor,'evidence',p_evidence)::text,'UTF8'),'sha256'),'hex');
 INSERT INTO zsl.zsl3_authority_events(event_type,build_run_id,certification_run_id,actor,evidence,evidence_sha256) VALUES('ACTIVATED',p_build,p_cert,p_actor,p_evidence,evsha) RETURNING authority_event_id INTO ev;
 UPDATE zsl.zsl3_authority_state SET build_run_id=p_build,certification_run_id=p_cert,authority_event_id=ev,updated_at=now() WHERE singleton;
 RETURN ev;
END$$;
CREATE OR REPLACE FUNCTION zsl.zsl3_revoke_active(p_actor text,p_evidence jsonb)
RETURNS bigint LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,zsl AS $$
DECLARE s zsl.zsl3_authority_state%ROWTYPE;ev bigint;evsha text;
BEGIN
 SELECT * INTO s FROM zsl.zsl3_authority_state WHERE singleton FOR UPDATE;
 IF s.build_run_id IS NULL THEN RAISE EXCEPTION 'ZSL3_NO_ACTIVE_AUTHORITY'; END IF;
 evsha:=encode(digest(convert_to(jsonb_build_object('eventType','REVOKED','buildRunId',s.build_run_id,'certificationRunId',s.certification_run_id,'actor',p_actor,'evidence',p_evidence)::text,'UTF8'),'sha256'),'hex');
 INSERT INTO zsl.zsl3_authority_events(event_type,build_run_id,certification_run_id,actor,evidence,evidence_sha256) VALUES('REVOKED',s.build_run_id,s.certification_run_id,p_actor,p_evidence,evsha) RETURNING authority_event_id INTO ev;
 UPDATE zsl.zsl3_authority_state SET build_run_id=NULL,certification_run_id=NULL,authority_event_id=ev,updated_at=now() WHERE singleton;
 RETURN ev;
END$$;
COMMIT;
