BEGIN;
-- PRE-GO-LIVE ONLY. Do not run after downstream systems rely on R1E evidence.

DROP VIEW IF EXISTS retail.r1e_effective_qualified_products;
DROP VIEW IF EXISTS retail.r1e_pending_captures;

DROP TRIGGER IF EXISTS trg_r1e_audit_fixtures ON retail.r1e_qa_fixtures;
DROP TRIGGER IF EXISTS trg_r1e_audit_binding ON retail.r1e_r1d_certification_binding;
DROP TRIGGER IF EXISTS trg_r1e_audit_results ON retail.r1e_qualification_results;
DROP TRIGGER IF EXISTS trg_r1e_audit_rulesets ON retail.r1e_match_rulesets;
DROP TRIGGER IF EXISTS trg_r1e_binding_history_guard ON retail.r1e_r1d_binding_history;
DROP TRIGGER IF EXISTS trg_r1e_certification_guard ON retail.r1e_certification_runs;
DROP TRIGGER IF EXISTS trg_r1e_fixture_guard ON retail.r1e_qa_fixtures;
DROP TRIGGER IF EXISTS trg_r1e_prepare_fixture ON retail.r1e_qa_fixtures;
DROP TRIGGER IF EXISTS trg_r1e_result_guard ON retail.r1e_qualification_results;
DROP TRIGGER IF EXISTS trg_r1e_ruleset_guard ON retail.r1e_match_rulesets;
DROP TRIGGER IF EXISTS trg_r1e_prepare_ruleset ON retail.r1e_match_rulesets;

DROP FUNCTION IF EXISTS retail.r1e_latest_certification_is_current(uuid);
DROP FUNCTION IF EXISTS retail.r1e_evaluate_capture(uuid,uuid,uuid,text,text);
DROP FUNCTION IF EXISTS retail.r1e_match_documents(jsonb,jsonb,jsonb,boolean);
DROP FUNCTION IF EXISTS retail.r1e_token_overlap(text,text);
DROP FUNCTION IF EXISTS retail.r1e_normalize_text(text);
DROP FUNCTION IF EXISTS retail.r1e_certify_ruleset(uuid,jsonb,text);
DROP FUNCTION IF EXISTS retail.r1e_validate_ruleset(jsonb);
DROP FUNCTION IF EXISTS retail.r1e_prepare_ruleset();
DROP FUNCTION IF EXISTS retail.r1e_ruleset_guard();
DROP FUNCTION IF EXISTS retail.r1e_bind_r1d_certification(uuid,uuid,text,text);
DROP FUNCTION IF EXISTS retail.r1e_r1d_binding_is_current();
DROP FUNCTION IF EXISTS retail.r1e_fixture_document(retail.r1e_qa_fixtures);
DROP FUNCTION IF EXISTS retail.r1e_prepare_fixture();
DROP FUNCTION IF EXISTS retail.r1e_fixture_guard();
DROP FUNCTION IF EXISTS retail.r1e_result_guard();
DROP FUNCTION IF EXISTS retail.r1e_certification_guard();
DROP FUNCTION IF EXISTS retail.r1e_history_guard();
DROP FUNCTION IF EXISTS retail.r1e_sha256_jsonb(jsonb);
DROP FUNCTION IF EXISTS retail.r1e_sha256_text(text);
DROP FUNCTION IF EXISTS retail_audit.r1e_log_retail_change();

DROP TABLE IF EXISTS retail.r1e_certification_runs;
DROP TABLE IF EXISTS retail.r1e_certification_policy;
DROP TABLE IF EXISTS retail.r1e_qa_fixtures;
DROP TABLE IF EXISTS retail.r1e_qualification_results;
DROP TABLE IF EXISTS retail.r1e_match_rulesets;
DROP TABLE IF EXISTS retail.r1e_r1d_binding_history;
DROP TABLE IF EXISTS retail.r1e_r1d_certification_binding;
DROP TABLE IF EXISTS retail.r1e_schema_state;

COMMIT;
