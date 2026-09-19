BEGIN;
-- PRE-GO-LIVE ONLY. V2 evidence must not be relied upon.

DROP TRIGGER IF EXISTS trg_r1d_audit_rate_policies ON retail.r1d_rate_policies;
DROP TRIGGER IF EXISTS trg_r1d_validate_certification_insert ON retail.r1d_certification_runs;
DROP TRIGGER IF EXISTS trg_r1d_r1c_history_guard ON retail.r1d_r1c_binding_history;
DROP TRIGGER IF EXISTS trg_r1d_budget_ledger_guard ON retail.r1d_budget_ledger;
DROP TRIGGER IF EXISTS trg_r1d_geo_events_guard ON retail.r1d_geo_activation_events;

DROP FUNCTION IF EXISTS retail.r1d_attach_claim_provenance(uuid,integer,uuid,text);
DROP FUNCTION IF EXISTS retail.r1d_claim_next_job_v2(text,uuid,text,boolean);
DROP FUNCTION IF EXISTS retail.r1d_finish_external_job(uuid,uuid,boolean,numeric,text,text,jsonb,integer,uuid,text);
DROP FUNCTION IF EXISTS retail.r1d_enqueue_external_attempt(uuid,uuid,uuid,jsonb);
DROP FUNCTION IF EXISTS retail.r1d_reconcile_stale_jobs(uuid,text);
DROP FUNCTION IF EXISTS retail.r1d_acquire_circuit_permit(uuid,uuid,timestamptz);
DROP FUNCTION IF EXISTS retail.r1d_complete_circuit_permit(uuid,uuid,uuid,boolean);
DROP FUNCTION IF EXISTS retail.r1d_reserve_rate_slot_v2(uuid,integer,timestamptz);
DROP FUNCTION IF EXISTS retail.r1d_consume_rate_slot(uuid,integer);
DROP FUNCTION IF EXISTS retail.r1d_release_rate_slot(uuid,integer);
DROP FUNCTION IF EXISTS retail.r1d_sync_schedule_state_v2(timestamptz,uuid,text);
DROP FUNCTION IF EXISTS retail.r1d_materialize_due_jobs_v2(timestamptz,integer,uuid,text,text);
DROP FUNCTION IF EXISTS retail.r1d_validate_runner_policy(jsonb);
DROP FUNCTION IF EXISTS retail.r1d_budget_period_start(text,timestamptz);
DROP FUNCTION IF EXISTS retail.r1d_set_audit_context(uuid,text);

DROP TABLE IF EXISTS retail.r1d_geo_transition_rules;
DROP TABLE IF EXISTS retail.r1d_rate_reservations;
DROP TABLE IF EXISTS retail.r1d_rate_policies;
DROP TABLE IF EXISTS retail.r1d_cost_model_violations;
DROP TABLE IF EXISTS retail.r1d_v2_state;

COMMIT;
