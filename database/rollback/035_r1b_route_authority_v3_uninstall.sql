BEGIN;
DROP VIEW IF EXISTS retail.effective_search_routes;
DROP TRIGGER IF EXISTS trg_r1b_audit_routes ON retail.search_route_bindings;
DROP TRIGGER IF EXISTS trg_r1b_audit_adapters ON retail.retail_search_adapters;
DROP TRIGGER IF EXISTS trg_r1b_audit_locations ON retail.search_locations;
DROP TRIGGER IF EXISTS trg_r1b_validate_route_approval ON retail.search_route_bindings;
DROP TRIGGER IF EXISTS trg_r1b_route_guard ON retail.search_route_bindings;
DROP TRIGGER IF EXISTS trg_r1b_prepare_route ON retail.search_route_bindings;
DROP TRIGGER IF EXISTS trg_r1b_adapter_immutable_after_cert ON retail.retail_search_adapters;
DROP TRIGGER IF EXISTS trg_r1b_adapter_prepare ON retail.retail_search_adapters;
DROP TRIGGER IF EXISTS trg_r1b_location_guard ON retail.search_locations;

DROP FUNCTION IF EXISTS retail_audit.r1b_log_retail_change();
DROP FUNCTION IF EXISTS retail.r1b_validate_route_approval();
DROP FUNCTION IF EXISTS retail.r1b_route_is_current(uuid);
DROP FUNCTION IF EXISTS retail.r1b_route_guard();
DROP FUNCTION IF EXISTS retail.r1b_prepare_route();
DROP FUNCTION IF EXISTS retail.r1b_route_authority_document(retail.search_route_bindings);
DROP FUNCTION IF EXISTS retail.r1b_source_authority_document(uuid);
DROP FUNCTION IF EXISTS retail.r1b_platform_authority_document(uuid);
DROP FUNCTION IF EXISTS retail.r1b_adapter_authority_document(uuid);
DROP FUNCTION IF EXISTS retail.r1b_adapter_is_certified_current(uuid);
DROP FUNCTION IF EXISTS retail.r1b_adapter_immutable_after_cert();
DROP FUNCTION IF EXISTS retail.r1b_adapter_prepare();
DROP FUNCTION IF EXISTS retail.r1b_adapter_certification_document(retail.retail_search_adapters);
DROP FUNCTION IF EXISTS retail.r1b_adapter_capability_document(retail.retail_search_adapters);
DROP FUNCTION IF EXISTS retail.r1b_location_guard();
DROP FUNCTION IF EXISTS retail.r1b_location_authority_document(uuid);
DROP FUNCTION IF EXISTS retail.r1b_sha256_jsonb(jsonb);

DROP TABLE IF EXISTS retail.search_route_bindings;
DROP TABLE IF EXISTS retail.retail_search_adapters;
DROP TABLE IF EXISTS retail.search_locations;
DROP TABLE IF EXISTS retail.r1b_schema_state;
COMMIT;

-- V3 uninstall is for failed pre-go-live installations only.
