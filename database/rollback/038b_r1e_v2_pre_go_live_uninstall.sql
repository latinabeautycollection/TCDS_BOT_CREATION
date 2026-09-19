BEGIN;
-- PRE-GO-LIVE ONLY. Do not use once R1E V2 evidence is relied upon.

DROP TRIGGER IF EXISTS trg_r1e_v2_certification_insert_guard
  ON retail.r1e_certification_runs;
DROP TRIGGER IF EXISTS trg_r1e_cert_policy_guard
  ON retail.r1e_certification_policies;
DROP TRIGGER IF EXISTS trg_r1e_prepare_cert_policy
  ON retail.r1e_certification_policies;

DROP FUNCTION IF EXISTS retail.r1e_result_is_current(uuid);
DROP FUNCTION IF EXISTS retail.r1e_upstream_identity_is_current(uuid,text);
DROP FUNCTION IF EXISTS retail.r1e_evaluate_capture_v2(uuid,uuid,uuid,text,text);
DROP FUNCTION IF EXISTS retail.r1e_observation_document(
  retail.raw_product_captures,
  retail.search_job_compilations,
  retail.retail_products
);
DROP FUNCTION IF EXISTS retail.r1e_match_documents_v2(jsonb,jsonb,jsonb,boolean);
DROP FUNCTION IF EXISTS retail.r1e_validate_ruleset_v2(jsonb);
DROP FUNCTION IF EXISTS retail.r1e_identifier_match_document(jsonb,jsonb);
DROP FUNCTION IF EXISTS retail.r1e_variant_match_document(jsonb,jsonb,jsonb);
DROP FUNCTION IF EXISTS retail.r1e_returned_variant_attributes(jsonb);
DROP FUNCTION IF EXISTS retail.r1e_target_variant_attributes(jsonb);
DROP FUNCTION IF EXISTS retail.r1e_compilation_target_document(uuid);
DROP FUNCTION IF EXISTS retail.r1e_contains_phrase(text,text);
DROP FUNCTION IF EXISTS retail.r1e_attempt_evidence_document(bigint);
DROP FUNCTION IF EXISTS retail.r1e_try_observation_lock(text);
DROP FUNCTION IF EXISTS retail.r1e_observation_lock_key(text);
DROP FUNCTION IF EXISTS retail.r1e_certify_policy(uuid,uuid,text,text);
DROP FUNCTION IF EXISTS retail.r1e_validate_cert_policy(jsonb);
DROP FUNCTION IF EXISTS retail.r1e_certify_ruleset_v2(uuid,jsonb,uuid,text,text);
DROP FUNCTION IF EXISTS retail.r1e_bind_r1d_certification_v2(uuid,uuid,text,text);
DROP FUNCTION IF EXISTS retail.r1e_assert_process_run(uuid,text[]);
DROP FUNCTION IF EXISTS retail.r1e_try_uuid(text);

DROP TABLE IF EXISTS retail.r1e_certification_policies;
DROP TABLE IF EXISTS retail.r1e_v2_state;

COMMIT;
