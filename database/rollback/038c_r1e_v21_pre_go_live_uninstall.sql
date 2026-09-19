BEGIN;
-- PRE-GO-LIVE ONLY. Do not run once R1E V2.1 evidence is relied upon.

DROP VIEW IF EXISTS retail.r1e_lineage_anomalies;

DROP TRIGGER IF EXISTS trg_r1e_v21_certification_insert_guard
  ON retail.r1e_certification_runs;
DROP TRIGGER IF EXISTS trg_r1e_audit_certification_policies
  ON retail.r1e_certification_policies;
DROP TRIGGER IF EXISTS trg_r1e_audit_duplicate_race_fixtures
  ON retail.r1e_duplicate_race_fixtures;
DROP TRIGGER IF EXISTS trg_r1e_audit_e2e_fixtures
  ON retail.r1e_e2e_qa_fixtures;
DROP TRIGGER IF EXISTS trg_r1e_duplicate_race_fixture_guard
  ON retail.r1e_duplicate_race_fixtures;
DROP TRIGGER IF EXISTS trg_r1e_prepare_duplicate_race_fixture
  ON retail.r1e_duplicate_race_fixtures;
DROP TRIGGER IF EXISTS trg_r1e_e2e_fixture_guard
  ON retail.r1e_e2e_qa_fixtures;
DROP TRIGGER IF EXISTS trg_r1e_prepare_e2e_fixture
  ON retail.r1e_e2e_qa_fixtures;

DROP FUNCTION IF EXISTS retail.r1e_v21_certification_insert_guard();
DROP FUNCTION IF EXISTS retail.r1e_duplicate_race_fixture_guard();
DROP FUNCTION IF EXISTS retail.r1e_prepare_duplicate_race_fixture();
DROP FUNCTION IF EXISTS retail.r1e_duplicate_race_fixture_document(
  retail.r1e_duplicate_race_fixtures
);
DROP FUNCTION IF EXISTS retail.r1e_e2e_fixture_guard();
DROP FUNCTION IF EXISTS retail.r1e_prepare_e2e_fixture();
DROP FUNCTION IF EXISTS retail.r1e_e2e_fixture_document(
  retail.r1e_e2e_qa_fixtures
);
DROP FUNCTION IF EXISTS retail.r1e_evaluate_capture_v21(
  uuid,uuid,uuid,text,text,boolean
);
DROP FUNCTION IF EXISTS retail.r1e_observation_document_v21(
  retail.raw_product_captures,
  retail.search_job_compilations,
  retail.retail_products
);
DROP FUNCTION IF EXISTS retail.r1e_resolve_attempt_for_capture(uuid);
DROP FUNCTION IF EXISTS retail.r1e_match_documents_v21(
  jsonb,jsonb,jsonb,boolean
);
DROP FUNCTION IF EXISTS retail.r1e_variant_match_document_v21(
  jsonb,jsonb,jsonb
);
DROP FUNCTION IF EXISTS retail.r1e_contains_identity_term(text,text);
DROP FUNCTION IF EXISTS retail.r1e_normalize_identity_phrase(text);
DROP FUNCTION IF EXISTS retail.r1e_canonical_attribute_value(text,text);
DROP FUNCTION IF EXISTS retail.r1e_contains_canonical_attribute(text,text,text);
DROP FUNCTION IF EXISTS retail.r1e_normalize_model_token(text);
DROP FUNCTION IF EXISTS retail.r1e_normalize_platform(text);
DROP FUNCTION IF EXISTS retail.r1e_normalize_generation(text);
DROP FUNCTION IF EXISTS retail.r1e_normalize_capacity(text);
DROP FUNCTION IF EXISTS retail.r1e_r1a_revision_identity_document(uuid,text);

DROP TABLE IF EXISTS retail.r1e_duplicate_race_fixtures;
DROP TABLE IF EXISTS retail.r1e_e2e_qa_fixtures;
DROP TABLE IF EXISTS retail.r1e_v21_state;

COMMIT;
