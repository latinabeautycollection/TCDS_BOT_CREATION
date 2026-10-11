BEGIN;
SET LOCAL search_path=pg_catalog,zsl,public,extensions;

CREATE TABLE IF NOT EXISTS zsl.zsl2_certification_evaluations_v214(
  evaluation_id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  normalization_run_id uuid NOT NULL REFERENCES zsl.zsl2_normalization_runs(normalization_run_id) ON DELETE RESTRICT,
  package_sha256 text NOT NULL CHECK(package_sha256 ~ '^[0-9a-f]{64}$'),
  policy_sha256 text NOT NULL CHECK(policy_sha256 ~ '^[0-9a-f]{64}$'),
  actor_id text NOT NULL,
  created_at timestamptz NOT NULL DEFAULT now()
);
CREATE TABLE IF NOT EXISTS zsl.zsl2_runtime_checks_v214(
  evaluation_id uuid NOT NULL REFERENCES zsl.zsl2_certification_evaluations_v214(evaluation_id) ON DELETE RESTRICT,
  normalization_run_id uuid NOT NULL REFERENCES zsl.zsl2_normalization_runs(normalization_run_id) ON DELETE RESTRICT,
  check_name text NOT NULL,
  passed boolean NOT NULL,
  measured_value jsonb NOT NULL DEFAULT '{}'::jsonb,
  evidence_sha256 text NOT NULL CHECK(evidence_sha256 ~ '^[0-9a-f]{64}$'),
  recorded_by_db_principal text NOT NULL DEFAULT session_user,
  created_at timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY(evaluation_id,check_name)
);

CREATE OR REPLACE FUNCTION zsl.zsl2_begin_evaluation_v214(p_run uuid,p_package_sha text,p_policy_sha text,p_actor text)
RETURNS uuid LANGUAGE plpgsql VOLATILE SECURITY DEFINER SET search_path=pg_catalog,zsl AS $$
DECLARE id uuid; r record;
BEGIN
 SELECT normalization_run_id,state,package_sha256,policy_sha256 INTO r FROM zsl.zsl2_normalization_runs WHERE normalization_run_id=p_run;
 IF r.normalization_run_id IS NULL OR r.state<>'RECONCILED' THEN RAISE EXCEPTION 'ZSL2_V214_EVALUATION_REQUIRES_RECONCILED'; END IF;
 IF r.package_sha256<>p_package_sha OR r.policy_sha256<>p_policy_sha THEN RAISE EXCEPTION 'ZSL2_V214_EVALUATION_BINDING_MISMATCH'; END IF;
 INSERT INTO zsl.zsl2_certification_evaluations_v214(normalization_run_id,package_sha256,policy_sha256,actor_id)
 VALUES(p_run,p_package_sha,p_policy_sha,p_actor) RETURNING evaluation_id INTO id;
 RETURN id;
END $$;

CREATE OR REPLACE FUNCTION zsl.zsl2_record_source_check_v214(p_run uuid,p_eval uuid,p_name text,p_passed boolean,p_measured jsonb,p_evidence_sha text)
RETURNS void LANGUAGE plpgsql VOLATILE SECURITY DEFINER SET search_path=pg_catalog,zsl AS $$
DECLARE allowed text[]:=ARRAY[
 'exact_source_set','bound_records_only','source_snapshot_immutable','normalization_checkpoints_complete','checkpoint_counters_reconcile',
 'zero_fatal_conflicts','zero_orphans','identity_hash_coverage','lineage_coverage','deterministic_replay','hud_ratio_reconciliation','zero_component_evidence',
 'coordinate_sanity','run_membership_complete','upstream_package_match','source_vintage_coherence','zip_zcta_separation','cbsa_authority_rules',
 'multi_parent_geography','territorial_pending_evidence_valid','page_performance_observed','zsl1_authority_decision_valid'
];
BEGIN
 IF NOT (p_name=ANY(allowed)) THEN RAISE EXCEPTION 'ZSL2_V214_SOURCE_CHECK_NAME_DENIED:%',p_name; END IF;
 IF NOT EXISTS(SELECT 1 FROM zsl.zsl2_certification_evaluations_v214 WHERE evaluation_id=p_eval AND normalization_run_id=p_run) THEN RAISE EXCEPTION 'ZSL2_V214_EVALUATION_MISMATCH'; END IF;
 INSERT INTO zsl.zsl2_runtime_checks_v214(evaluation_id,normalization_run_id,check_name,passed,measured_value,evidence_sha256)
 VALUES(p_eval,p_run,p_name,p_passed,p_measured,p_evidence_sha);
END $$;

CREATE OR REPLACE FUNCTION zsl.zsl2_record_runtime_check_v214(p_run uuid,p_eval uuid,p_name text,p_passed boolean,p_measured jsonb,p_evidence_sha text)
RETURNS void LANGUAGE plpgsql VOLATILE SECURITY DEFINER SET search_path=pg_catalog,zsl AS $$
DECLARE allowed text[]:=ARRAY[
 'postgres_performance_runtime_pass','cross_domain_write_denial','dependency_freeze_complete','postgres_integration_tests_pass',
 'rbac_runtime_pass','activation_runtime_pass','rollback_runtime_pass','downstream_contract_compatibility'
];
BEGIN
 IF NOT (p_name=ANY(allowed)) THEN RAISE EXCEPTION 'ZSL2_V214_RUNTIME_CHECK_NAME_DENIED:%',p_name; END IF;
 IF NOT EXISTS(SELECT 1 FROM zsl.zsl2_certification_evaluations_v214 WHERE evaluation_id=p_eval AND normalization_run_id=p_run) THEN RAISE EXCEPTION 'ZSL2_V214_EVALUATION_MISMATCH'; END IF;
 INSERT INTO zsl.zsl2_runtime_checks_v214(evaluation_id,normalization_run_id,check_name,passed,measured_value,evidence_sha256)
 VALUES(p_eval,p_run,p_name,p_passed,p_measured,p_evidence_sha);
END $$;

CREATE OR REPLACE FUNCTION zsl.zsl2_finalize_certification_v214(p_run uuid,p_eval uuid,p_git_sha text,p_upstream_binding_sha text,p_evidence jsonb)
RETURNS TABLE(certification_run_id uuid,status text)
LANGUAGE plpgsql VOLATILE SECURITY DEFINER SET search_path=pg_catalog,zsl,extensions AS $$
DECLARE e record; r record; cid uuid; missing bigint; failed bigint; final_status text; ev_sha text;
DECLARE required text[]:=ARRAY[
 'exact_source_set','bound_records_only','source_snapshot_immutable','normalization_checkpoints_complete','checkpoint_counters_reconcile',
 'zero_fatal_conflicts','zero_orphans','identity_hash_coverage','lineage_coverage','deterministic_replay','hud_ratio_reconciliation','zero_component_evidence',
 'coordinate_sanity','run_membership_complete','upstream_package_match','source_vintage_coherence','zip_zcta_separation','cbsa_authority_rules',
 'multi_parent_geography','territorial_pending_evidence_valid','page_performance_observed','zsl1_authority_decision_valid',
 'postgres_performance_runtime_pass','cross_domain_write_denial','dependency_freeze_complete','postgres_integration_tests_pass','rbac_runtime_pass',
 'activation_runtime_pass','rollback_runtime_pass','downstream_contract_compatibility'
];
BEGIN
 PERFORM pg_advisory_xact_lock(hashtextextended('TCDS:ZSL2:V214:CERT:'||p_run::text,0));
 SELECT * INTO e FROM zsl.zsl2_certification_evaluations_v214 WHERE evaluation_id=p_eval AND normalization_run_id=p_run;
 SELECT normalization_run_id,state,package_sha256,policy_sha256,engine_version INTO r FROM zsl.zsl2_normalization_runs WHERE normalization_run_id=p_run;
 IF e.evaluation_id IS NULL OR r.state<>'RECONCILED' THEN RAISE EXCEPTION 'ZSL2_V214_CERT_EVALUATION_INVALID'; END IF;
 IF e.package_sha256<>r.package_sha256 OR e.policy_sha256<>r.policy_sha256 THEN RAISE EXCEPTION 'ZSL2_V214_CERT_BINDING_MISMATCH'; END IF;
 IF NOT zsl.zsl2_zsl1_authority_decision_current_v214(p_run) THEN RAISE EXCEPTION 'ZSL2_V214_ZSL1_AUTHORITY_NOT_CURRENT'; END IF;
 SELECT count(*) INTO missing FROM unnest(required) n WHERE NOT EXISTS(SELECT 1 FROM zsl.zsl2_runtime_checks_v214 c WHERE c.evaluation_id=p_eval AND c.normalization_run_id=p_run AND c.check_name=n);
 SELECT count(*) INTO failed FROM zsl.zsl2_runtime_checks_v214 c WHERE c.evaluation_id=p_eval AND c.normalization_run_id=p_run AND c.check_name=ANY(required) AND NOT c.passed;
 final_status:=CASE WHEN missing=0 AND failed=0 THEN 'CERTIFIED' ELSE 'FAILED' END;
 ev_sha:=encode(digest(convert_to(coalesce((SELECT string_agg(check_name||'|'||passed::text||'|'||evidence_sha256,E'\n' ORDER BY check_name) FROM zsl.zsl2_runtime_checks_v214 WHERE evaluation_id=p_eval),'')||'|'||coalesce(p_evidence::text,''),'UTF8'),'sha256'),'hex');
 INSERT INTO zsl.zsl2_certification_runs(normalization_run_id,engine_version,package_sha256,git_sha,policy_sha256,upstream_binding_sha256,status,evidence,evidence_sha256)
 VALUES(p_run,'zsl2-v2.1.0',e.package_sha256,p_git_sha,e.policy_sha256,p_upstream_binding_sha,final_status,p_evidence||jsonb_build_object('evaluation_id',p_eval,'v214_required_checks',required,'missing_count',missing,'failed_count',failed),ev_sha)
 RETURNING zsl2_certification_runs.certification_run_id INTO cid;
 RETURN QUERY SELECT cid,final_status;
END $$;

-- Replace the generic certification insert guard with V2.1.4 exact evaluation enforcement.
CREATE OR REPLACE FUNCTION zsl.zsl2_certification_guard() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,zsl AS $$
BEGIN
 IF NEW.status='CERTIFIED' THEN
  IF NOT EXISTS(
   SELECT 1 FROM zsl.zsl2_certification_evaluations_v214 e
   WHERE e.normalization_run_id=NEW.normalization_run_id AND e.package_sha256=NEW.package_sha256 AND e.policy_sha256=NEW.policy_sha256
     AND NEW.evidence->>'evaluation_id'=e.evaluation_id::text
  ) THEN RAISE EXCEPTION 'ZSL2_V214_CERT_REQUIRES_V214_EVALUATION'; END IF;
  IF NOT zsl.zsl2_zsl1_authority_decision_current_v214(NEW.normalization_run_id) THEN RAISE EXCEPTION 'ZSL2_V214_CERT_ZSL1_AUTHORITY_INVALID'; END IF;
 END IF;
 RETURN NEW;
END $$;
DROP TRIGGER IF EXISTS trg_zsl2_cert_guard ON zsl.zsl2_certification_runs;
CREATE TRIGGER trg_zsl2_cert_guard BEFORE INSERT ON zsl.zsl2_certification_runs FOR EACH ROW EXECUTE FUNCTION zsl.zsl2_certification_guard();

REVOKE ALL ON zsl.zsl2_certification_evaluations_v214,zsl.zsl2_runtime_checks_v214 FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION zsl.zsl2_begin_evaluation_v214(uuid,text,text,text),zsl.zsl2_record_source_check_v214(uuid,uuid,text,boolean,jsonb,text),zsl.zsl2_record_runtime_check_v214(uuid,uuid,text,boolean,jsonb,text),zsl.zsl2_finalize_certification_v214(uuid,uuid,text,text,jsonb) FROM PUBLIC;
DO $$ BEGIN
 IF EXISTS(SELECT 1 FROM pg_roles WHERE rolname='zsl2_certifier') THEN
  GRANT SELECT ON zsl.zsl2_certification_evaluations_v214,zsl.zsl2_runtime_checks_v214 TO zsl2_certifier;
  GRANT EXECUTE ON FUNCTION zsl.zsl2_begin_evaluation_v214(uuid,text,text,text),zsl.zsl2_record_source_check_v214(uuid,uuid,text,boolean,jsonb,text),zsl.zsl2_finalize_certification_v214(uuid,uuid,text,text,jsonb) TO zsl2_certifier;
 END IF;
 IF EXISTS(SELECT 1 FROM pg_roles WHERE rolname='zsl2_runtime_tester') THEN
  GRANT SELECT ON zsl.zsl2_certification_evaluations_v214,zsl.zsl2_runtime_checks_v214 TO zsl2_runtime_tester;
  GRANT EXECUTE ON FUNCTION zsl.zsl2_record_runtime_check_v214(uuid,uuid,text,boolean,jsonb,text) TO zsl2_runtime_tester;
 END IF;
END $$;

COMMIT;
