BEGIN;

CREATE OR REPLACE FUNCTION zsl.append_audit_event(p_type text, p_actor text, p_data jsonb)
 RETURNS bigint
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'zsl', 'pg_temp'
AS $function$
DECLARE
  id bigint;
  sha text;
BEGIN
  IF btrim(p_type)='' OR btrim(p_actor)='' OR jsonb_typeof(p_data)<>'object' THEN
    RAISE EXCEPTION 'INVALID_AUDIT_EVENT';
  END IF;
  sha := encode(digest(convert_to(jsonb_build_object(
      'event_type',p_type,'actor',p_actor,'event_data',p_data
    )::text,'UTF8'),'sha256'),'hex');
  INSERT INTO zsl.ingest_audit_events(event_type,actor,event_data,event_sha256)
  VALUES(p_type,p_actor,p_data,sha) RETURNING audit_event_id INTO id;
  RETURN id;
END $function$;

CREATE OR REPLACE FUNCTION zsl.append_ingest_audit_event(p_run uuid, p_type text, p_actor text, p_data jsonb)
 RETURNS bigint
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'zsl', 'pg_temp'
AS $function$
DECLARE id bigint;sha text;BEGIN IF NOT EXISTS(SELECT 1 FROM zsl.ingest_runs WHERE ingest_run_id=p_run) THEN RAISE EXCEPTION 'INGEST_RUN_NOT_FOUND';END IF;IF btrim(p_type)='' OR btrim(p_actor)='' OR jsonb_typeof(p_data)<>'object' THEN RAISE EXCEPTION 'INVALID_AUDIT_EVENT';END IF;
sha:=encode(digest(convert_to(jsonb_build_object('ingest_run_id',p_run,'event_type',p_type,'actor',p_actor,'event_data',p_data)::text,'UTF8'),'sha256'),'hex');
INSERT INTO zsl.ingest_audit_events(ingest_run_id,event_type,actor,event_data,event_sha256) VALUES(p_run,p_type,p_actor,p_data,sha) RETURNING audit_event_id INTO id;RETURN id;END $function$;

CREATE OR REPLACE FUNCTION zsl.zsl2_sha256_jsonb(p_doc jsonb)
 RETURNS text
 LANGUAGE sql
 IMMUTABLE PARALLEL SAFE STRICT
AS $function$
 SELECT encode(digest(convert_to(p_doc::text,'UTF8'),'sha256'),'hex')
$function$;

CREATE OR REPLACE FUNCTION zsl.zsl3_activate(p_build uuid, p_cert uuid, p_actor text, p_evidence jsonb)
 RETURNS bigint
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'zsl'
AS $function$
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
END$function$;

CREATE OR REPLACE FUNCTION zsl.zsl3_revoke_active(p_actor text, p_evidence jsonb)
 RETURNS bigint
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'zsl'
AS $function$
DECLARE s zsl.zsl3_authority_state%ROWTYPE;ev bigint;evsha text;
BEGIN
 SELECT * INTO s FROM zsl.zsl3_authority_state WHERE singleton FOR UPDATE;
 IF s.build_run_id IS NULL THEN RAISE EXCEPTION 'ZSL3_NO_ACTIVE_AUTHORITY'; END IF;
 evsha:=encode(digest(convert_to(jsonb_build_object('eventType','REVOKED','buildRunId',s.build_run_id,'certificationRunId',s.certification_run_id,'actor',p_actor,'evidence',p_evidence)::text,'UTF8'),'sha256'),'hex');
 INSERT INTO zsl.zsl3_authority_events(event_type,build_run_id,certification_run_id,actor,evidence,evidence_sha256) VALUES('REVOKED',s.build_run_id,s.certification_run_id,p_actor,p_evidence,evsha) RETURNING authority_event_id INTO ev;
 UPDATE zsl.zsl3_authority_state SET build_run_id=NULL,certification_run_id=NULL,authority_event_id=ev,updated_at=now() WHERE singleton;
 RETURN ev;
END$function$;

CREATE OR REPLACE FUNCTION zsl.zsl4_activate(p_build uuid, p_cert uuid, p_actor text, p_evidence jsonb)
 RETURNS bigint
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'zsl'
AS $function$DECLARE ev bigint;cr zsl.zsl4_certification_runs%ROWTYPE;BEGIN PERFORM pg_advisory_xact_lock(hashtextextended('TCDS:ZSL4:ACTIVATE',0));SELECT * INTO cr FROM zsl.zsl4_certification_runs WHERE certification_run_id=p_cert AND build_run_id=p_build;IF cr.certification_run_id IS NULL OR cr.status<>'CERTIFIED' THEN RAISE EXCEPTION 'ZSL4_CERTIFICATION_NOT_CERTIFIED';END IF;IF NOT zsl.zsl4_bindings_still_valid(p_build) THEN RAISE EXCEPTION 'ZSL4_UPSTREAM_BINDINGS_INVALID';END IF;INSERT INTO zsl.zsl4_authority_events(event_type,build_run_id,certification_run_id,actor,evidence,evidence_sha256) VALUES('ACTIVATED',p_build,p_cert,p_actor,p_evidence,encode(digest(convert_to(p_evidence::text,'UTF8'),'sha256'),'hex')) RETURNING authority_event_id INTO ev;UPDATE zsl.zsl4_authority_state SET build_run_id=p_build,certification_run_id=p_cert,authority_event_id=ev,updated_at=now() WHERE singleton;RETURN ev;END$function$;

CREATE OR REPLACE FUNCTION zsl.zsl4_finalize_runtime_check_run(p_run uuid, p_status text, p_evidence jsonb)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'zsl'
AS $function$DECLARE cur text;BEGIN SELECT status INTO cur FROM zsl.zsl4_runtime_check_runs WHERE runtime_check_run_id=p_run FOR UPDATE;IF cur<>'RUNNING' THEN RAISE EXCEPTION 'ZSL4_RUNTIME_CHECK_RUN_ALREADY_FINAL';END IF;IF p_status NOT IN('PASS','FAIL') THEN RAISE EXCEPTION 'ZSL4_BAD_RUNTIME_CHECK_STATUS';END IF;UPDATE zsl.zsl4_runtime_check_runs SET status=p_status,completed_at=now(),evidence_document=p_evidence,evidence_sha256=encode(digest(convert_to(p_evidence::text,'UTF8'),'sha256'),'hex') WHERE runtime_check_run_id=p_run;END$function$;

CREATE OR REPLACE FUNCTION zsl.zsl4_revoke_active(p_actor text, p_evidence jsonb)
 RETURNS bigint
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'zsl'
AS $function$DECLARE s zsl.zsl4_authority_state%ROWTYPE;ev bigint;BEGIN PERFORM pg_advisory_xact_lock(hashtextextended('TCDS:ZSL4:ACTIVATE',0));SELECT * INTO s FROM zsl.zsl4_authority_state WHERE singleton FOR UPDATE;IF s.build_run_id IS NULL THEN RAISE EXCEPTION 'ZSL4_NO_ACTIVE_AUTHORITY';END IF;INSERT INTO zsl.zsl4_authority_events(event_type,build_run_id,certification_run_id,actor,evidence,evidence_sha256) VALUES('REVOKED',s.build_run_id,s.certification_run_id,p_actor,p_evidence,encode(digest(convert_to(p_evidence::text,'UTF8'),'sha256'),'hex')) RETURNING authority_event_id INTO ev;UPDATE zsl.zsl4_authority_state SET build_run_id=NULL,certification_run_id=NULL,authority_event_id=ev,updated_at=now() WHERE singleton;RETURN ev;END$function$;

COMMIT;

