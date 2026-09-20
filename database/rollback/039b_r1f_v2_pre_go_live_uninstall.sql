BEGIN;
-- PRE-GO-LIVE ONLY. This restores the R1F V1 base before any V2 evidence is relied upon.

DROP VIEW IF EXISTS retail.r1f_effective_search_recommendations;
DROP VIEW IF EXISTS retail.r1f_local_temporal_search_intelligence;

DROP TRIGGER IF EXISTS trg_r1f_v2_certification_insert_guard
  ON retail.r1f_certification_runs;
DROP TRIGGER IF EXISTS trg_r1f_audit_e2e_scenarios
  ON retail.r1f_e2e_qa_scenarios;
DROP TRIGGER IF EXISTS trg_r1f_e2e_scenario_guard
  ON retail.r1f_e2e_qa_scenarios;
DROP TRIGGER IF EXISTS trg_r1f_prepare_e2e_scenario
  ON retail.r1f_e2e_qa_scenarios;

DROP FUNCTION IF EXISTS retail.r1f_v2_certification_insert_guard();
DROP FUNCTION IF EXISTS retail.r1f_r1e_identity_is_current(uuid,text);
DROP FUNCTION IF EXISTS retail.r1f_compilation_identity_is_current(
  uuid,uuid,uuid,text,uuid,text
);
DROP FUNCTION IF EXISTS retail.r1f_validate_certification_policy(jsonb);
DROP FUNCTION IF EXISTS retail.r1f_e2e_scenario_guard();
DROP FUNCTION IF EXISTS retail.r1f_prepare_e2e_scenario();
DROP FUNCTION IF EXISTS retail.r1f_e2e_scenario_document(
  retail.r1f_e2e_qa_scenarios
);
DROP FUNCTION IF EXISTS retail.r1f_simulate_strategy(jsonb,jsonb);
DROP FUNCTION IF EXISTS retail.r1f_rank_locations(jsonb,jsonb);
DROP FUNCTION IF EXISTS retail.r1f_generate_recommendations_v2(
  uuid,timestamptz,uuid,text,text,boolean,uuid
);
DROP FUNCTION IF EXISTS retail.r1f_build_intelligence_v2(
  uuid,timestamptz,uuid,text,text,boolean,uuid
);
DROP FUNCTION IF EXISTS retail.r1f_ingest_completed_job_v2(
  uuid,uuid,text,text,boolean,uuid
);
DROP FUNCTION IF EXISTS retail.r1f_authorized_child_compilations(
  uuid,uuid,timestamptz,integer
);
DROP FUNCTION IF EXISTS retail.r1f_score_document_v2(jsonb,jsonb);
DROP FUNCTION IF EXISTS retail.r1f_validate_qa_fixture(text,jsonb,jsonb);
DROP FUNCTION IF EXISTS retail.r1f_assert_window_end(timestamptz,jsonb);
DROP FUNCTION IF EXISTS retail.r1f_location_timezone(uuid);
DROP FUNCTION IF EXISTS retail.r1f_valid_timezone(text);
DROP FUNCTION IF EXISTS retail.r1f_economic_amount_document(jsonb);
DROP FUNCTION IF EXISTS retail.r1f_fulfillment_mode_for_capture(uuid);
DROP FUNCTION IF EXISTS retail.r1f_normalize_condition(text);

DROP TABLE IF EXISTS retail.r1f_e2e_qa_scenarios;
DROP TABLE IF EXISTS retail.r1f_v2_state;

DROP INDEX IF EXISTS retail.uq_r1f_v2_job_fact_engine;
DROP INDEX IF EXISTS retail.uq_r1f_v2_observation_fact_engine;
DROP INDEX IF EXISTS retail.idx_r1f_v2_economic_baseline;

ALTER TABLE retail.r1f_job_facts
  DROP COLUMN IF EXISTS engine_version,
  DROP COLUMN IF EXISTS reported_records_collected,
  DROP COLUMN IF EXISTS authoritative_capture_count,
  DROP COLUMN IF EXISTS collection_reconciliation_status,
  DROP COLUMN IF EXISTS actual_cost_coverage,
  DROP COLUMN IF EXISTS location_timezone,
  DROP COLUMN IF EXISTS local_weekday,
  DROP COLUMN IF EXISTS local_hour,
  DROP COLUMN IF EXISTS certification_fixture,
  DROP COLUMN IF EXISTS certification_batch_id;

ALTER TABLE retail.r1f_observation_facts
  DROP COLUMN IF EXISTS engine_version,
  DROP COLUMN IF EXISTS condition_normalized,
  DROP COLUMN IF EXISTS fulfillment_mode,
  DROP COLUMN IF EXISTS currency_code,
  DROP COLUMN IF EXISTS economic_amount,
  DROP COLUMN IF EXISTS economic_price_basis,
  DROP COLUMN IF EXISTS certification_fixture,
  DROP COLUMN IF EXISTS certification_batch_id;

ALTER TABLE retail.r1f_intelligence_snapshots
  DROP COLUMN IF EXISTS engine_version,
  DROP COLUMN IF EXISTS actual_cost_jobs,
  DROP COLUMN IF EXISTS estimated_cost_jobs,
  DROP COLUMN IF EXISTS actual_cost_coverage_pct,
  DROP COLUMN IF EXISTS certification_fixture,
  DROP COLUMN IF EXISTS certification_batch_id;

ALTER TABLE retail.r1f_search_recommendations
  DROP COLUMN IF EXISTS engine_version,
  DROP COLUMN IF EXISTS recommended_child_compilation_ids,
  DROP COLUMN IF EXISTS certification_fixture,
  DROP COLUMN IF EXISTS certification_batch_id;

ALTER TABLE retail.r1f_certification_runs
  DROP COLUMN IF EXISTS e2e_results,
  DROP COLUMN IF EXISTS e2e_manifest_sha256,
  DROP COLUMN IF EXISTS ranking_results,
  DROP COLUMN IF EXISTS convergence_results,
  DROP COLUMN IF EXISTS concurrency_results;

ALTER TABLE retail.r1f_job_facts
  ADD CONSTRAINT r1f_job_facts_r1d_job_id_r1e_certification_run_id_key
  UNIQUE(r1d_job_id,r1e_certification_run_id);

ALTER TABLE retail.r1f_observation_facts
  ADD CONSTRAINT r1f_observation_facts_r1e_result_id_key
  UNIQUE(r1e_result_id);

CREATE TRIGGER trg_r1f_certification_insert_guard
BEFORE INSERT ON retail.r1f_certification_runs
FOR EACH ROW EXECUTE FUNCTION retail.r1f_certification_insert_guard();

GRANT EXECUTE ON FUNCTION retail.r1f_ingest_completed_job(uuid,uuid,text,text)
  TO retail_r1f_worker;
GRANT EXECUTE ON FUNCTION retail.r1f_build_intelligence(
  uuid,timestamptz,uuid,text,text
) TO retail_r1f_worker;
GRANT EXECUTE ON FUNCTION retail.r1f_generate_recommendations(
  uuid,timestamptz,uuid,text,text
) TO retail_r1f_worker;

COMMIT;
