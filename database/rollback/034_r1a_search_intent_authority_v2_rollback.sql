BEGIN;

-- Rollback is intentionally fail-closed and refuses removal if downstream
-- objects have dependencies. Do not use CASCADE.
DROP VIEW IF EXISTS retail.effective_search_targets;
DROP TRIGGER IF EXISTS trg_r1a_audit_search_target_revisions ON retail.search_target_revisions;
DROP TRIGGER IF EXISTS trg_r1a_audit_search_targets ON retail.search_targets;
DROP TRIGGER IF EXISTS trg_r1a_targets_validate_activation ON retail.search_targets;
DROP TRIGGER IF EXISTS trg_r1a_targets_touch ON retail.search_targets;
DROP TRIGGER IF EXISTS trg_r1a_revision_immutable ON retail.search_target_revisions;
DROP TRIGGER IF EXISTS trg_r1a_prepare_revision ON retail.search_target_revisions;

DROP FUNCTION IF EXISTS retail_audit.r1a_log_retail_change();
DROP FUNCTION IF EXISTS retail.r1a_validate_activation();
DROP FUNCTION IF EXISTS retail.r1a_touch_updated_at();
DROP FUNCTION IF EXISTS retail.r1a_revision_is_current(uuid,integer);
DROP FUNCTION IF EXISTS retail.r1a_revision_immutable();
DROP FUNCTION IF EXISTS retail.r1a_prepare_revision();
DROP FUNCTION IF EXISTS retail.r1a_revision_business_document(retail.search_target_revisions);
DROP FUNCTION IF EXISTS retail.r1a_current_upstream_hash(bigint);
DROP FUNCTION IF EXISTS retail.r1a_current_upstream_document(bigint);
DROP FUNCTION IF EXISTS retail.r1a_sha256_jsonb(jsonb);

DROP TABLE IF EXISTS retail.search_target_revisions;
DROP TABLE IF EXISTS retail.search_targets;
DROP TABLE IF EXISTS retail.r1a_schema_state;

-- Process registry row is retained as historical governance evidence.
COMMIT;
