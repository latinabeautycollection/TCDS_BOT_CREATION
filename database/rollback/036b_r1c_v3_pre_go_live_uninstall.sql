BEGIN;
-- PRE-GO-LIVE ONLY. Run before V2 uninstall if V3 installation must be removed.

DROP TRIGGER IF EXISTS trg_r1c_audit_r1b_binding_history
  ON retail.r1c_r1b_binding_history;
DROP TRIGGER IF EXISTS trg_r1c_audit_r1b_binding
  ON retail.r1c_r1b_certification_binding;

DROP FUNCTION IF EXISTS retail.r1c_assert_runtime_compiler_v3(uuid,text,text,text);
DROP FUNCTION IF EXISTS retail.r1c_compiler_functions_current(uuid);
DROP FUNCTION IF EXISTS retail.r1c_build_query_v3(text,text,jsonb,jsonb);
DROP FUNCTION IF EXISTS retail.r1c_scraper_authority_document(uuid);
DROP FUNCTION IF EXISTS retail.r1c_bind_r1b_certification(uuid,uuid,text,text);
DROP FUNCTION IF EXISTS retail.r1c_jsonb_text_union(jsonb,jsonb);
DROP FUNCTION IF EXISTS retail.r1c_digest_sha256(bytea);

DROP TABLE IF EXISTS retail.r1c_r1b_binding_history;
DROP TABLE IF EXISTS retail.r1c_v3_state;

COMMIT;
