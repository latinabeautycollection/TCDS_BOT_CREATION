BEGIN;
-- PRE-GO-LIVE ONLY. Do not use after R1F evidence is relied upon.

DROP VIEW IF EXISTS retail.r1f_effective_search_recommendations;
DROP VIEW IF EXISTS retail.r1f_temporal_search_intelligence;
DROP VIEW IF EXISTS retail.r1f_proposed_search_recommendations;

DROP TRIGGER IF EXISTS trg_r1f_audit_binding
  ON retail.r1f_r1e_certification_binding;
DROP TRIGGER IF EXISTS trg_r1f_audit_snapshots
  ON retail.r1f_intelligence_snapshots;
DROP TRIGGER IF EXISTS trg_r1f_audit_observation_facts
  ON retail.r1f_observation_facts;
DROP TRIGGER IF EXISTS trg_r1f_audit_job_facts
  ON retail.r1f_job_facts;
DROP TRIGGER IF EXISTS trg_r1f_audit_recommendations
  ON retail.r1f_search_recommendations;
DROP TRIGGER IF EXISTS trg_r1f_audit_qa_fixtures
  ON retail.r1f_qa_fixtures;
DROP TRIGGER IF EXISTS trg_r1f_audit_certification_policy
  ON retail.r1f_certification_policies;
DROP TRIGGER IF EXISTS trg_r1f_audit_policy
  ON retail.r1f_intelligence_policies;

DROP TRIGGER IF EXISTS trg_r1f_certification_guard
  ON retail.r1f_certification_runs;
DROP TRIGGER IF EXISTS trg_r1f_fixture_guard
  ON retail.r1f_qa_fixtures;
DROP TRIGGER IF EXISTS trg_r1f_prepare_fixture
  ON retail.r1f_qa_fixtures;
DROP TRIGGER IF EXISTS trg_r1f_recommendation_guard
  ON retail.r1f_search_recommendations;
DROP TRIGGER IF EXISTS trg_r1f_snapshot_guard
  ON retail.r1f_intelligence_snapshots;
DROP TRIGGER IF EXISTS trg_r1f_observation_guard
  ON retail.r1f_observation_facts;
DROP TRIGGER IF EXISTS trg_r1f_fact_guard
  ON retail.r1f_job_facts;
DROP TRIGGER IF EXISTS trg_r1f_cert_policy_guard
  ON retail.r1f_certification_policies;
DROP TRIGGER IF EXISTS trg_r1f_prepare_cert_policy
  ON retail.r1f_certification_policies;
DROP TRIGGER IF EXISTS trg_r1f_policy_guard
  ON retail.r1f_intelligence_policies;
DROP TRIGGER IF EXISTS trg_r1f_prepare_policy
  ON retail.r1f_intelligence_policies;
DROP TRIGGER IF EXISTS trg_r1f_binding_history_guard
  ON retail.r1f_r1e_binding_history;

DROP FUNCTION IF EXISTS retail.r1f_latest_certification_is_current();
DROP FUNCTION IF EXISTS retail.r1f_certification_guard();
DROP FUNCTION IF EXISTS retail.r1f_certify_certification_policy(uuid,uuid,text,text);
DROP FUNCTION IF EXISTS retail.r1f_validate_certification_policy(jsonb);
DROP FUNCTION IF EXISTS retail.r1f_cert_policy_guard();
DROP FUNCTION IF EXISTS retail.r1f_prepare_cert_policy();
DROP FUNCTION IF EXISTS retail.r1f_fixture_guard();
DROP FUNCTION IF EXISTS retail.r1f_prepare_fixture();
DROP FUNCTION IF EXISTS retail.r1f_fixture_document(retail.r1f_qa_fixtures);
DROP FUNCTION IF EXISTS retail.r1f_generate_recommendations(uuid,timestamptz,uuid,text,text);
DROP FUNCTION IF EXISTS retail.r1f_recommendation_decision(jsonb,jsonb);
DROP FUNCTION IF EXISTS retail.r1f_recommendation_guard();
DROP FUNCTION IF EXISTS retail.r1f_build_intelligence(uuid,timestamptz,uuid,text,text);
DROP FUNCTION IF EXISTS retail.r1f_score_document(jsonb,jsonb);
DROP FUNCTION IF EXISTS retail.r1f_wilson_lower_bound(integer,integer,numeric);
DROP FUNCTION IF EXISTS retail.r1f_snapshot_guard();
DROP FUNCTION IF EXISTS retail.r1f_ingest_completed_job(uuid,uuid,text,text);
DROP FUNCTION IF EXISTS retail.r1f_observation_guard();
DROP FUNCTION IF EXISTS retail.r1f_fact_guard();
DROP FUNCTION IF EXISTS retail.r1f_certify_policy(uuid,uuid,text,text);
DROP FUNCTION IF EXISTS retail.r1f_validate_policy(jsonb);
DROP FUNCTION IF EXISTS retail.r1f_policy_guard();
DROP FUNCTION IF EXISTS retail.r1f_prepare_policy();
DROP FUNCTION IF EXISTS retail.r1f_bind_r1e_certification(uuid,uuid,text,text);
DROP FUNCTION IF EXISTS retail.r1f_assert_process_run(uuid,text[]);
DROP FUNCTION IF EXISTS retail.r1f_r1e_binding_is_current();
DROP FUNCTION IF EXISTS retail.r1f_try_integer(text);
DROP FUNCTION IF EXISTS retail.r1f_try_numeric(text);
DROP FUNCTION IF EXISTS retail.r1f_sha256_jsonb(jsonb);
DROP FUNCTION IF EXISTS retail.r1f_sha256_text(text);
DROP FUNCTION IF EXISTS retail.r1f_history_guard();
DROP FUNCTION IF EXISTS retail_audit.r1f_log_retail_change();

DROP TABLE IF EXISTS retail.r1f_certification_runs;
DROP TABLE IF EXISTS retail.r1f_certification_policies;
DROP TABLE IF EXISTS retail.r1f_qa_fixtures;
DROP TABLE IF EXISTS retail.r1f_search_recommendations;
DROP TABLE IF EXISTS retail.r1f_intelligence_snapshots;
DROP TABLE IF EXISTS retail.r1f_observation_facts;
DROP TABLE IF EXISTS retail.r1f_job_facts;
DROP TABLE IF EXISTS retail.r1f_intelligence_policies;
DROP TABLE IF EXISTS retail.r1f_r1e_binding_history;
DROP TABLE IF EXISTS retail.r1f_r1e_certification_binding;
DROP TABLE IF EXISTS retail.r1f_schema_state;

COMMIT;
