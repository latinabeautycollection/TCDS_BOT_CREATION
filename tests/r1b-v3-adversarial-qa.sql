-- R1B V3 FREEZE CANDIDATE — EXECUTABLE DATABASE ASSERTIONS
-- Safe read-only/static assertions; active mutation tests are in active-negative-tests.ts.

DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM retail.r1b_schema_state WHERE singleton AND schema_version='3.0.0') THEN
    RAISE EXCEPTION 'G01 FAIL: R1B schema version';
  END IF;
  IF retail.r1b_r1a_binding_is_current() IS NOT TRUE THEN
    RAISE EXCEPTION 'G02 FAIL: exact R1A certification binding';
  END IF;
  IF EXISTS (
    SELECT 1 FROM retail.search_locations
    WHERE location_type='store' AND (platform_id IS NULL OR retailer_store_id IS NULL)
  ) THEN RAISE EXCEPTION 'G03 FAIL: store platform binding'; END IF;
  IF EXISTS (
    SELECT 1 FROM (
      SELECT platform_id,retailer_store_id,count(*) n
      FROM retail.search_locations WHERE location_type='store'
      GROUP BY 1,2 HAVING count(*)>1
    ) x
  ) THEN RAISE EXCEPTION 'G04 FAIL: duplicate retailer store identity'; END IF;
  IF EXISTS (
    SELECT 1 FROM retail.retail_search_adapters
    WHERE certification_status='certified_dynamic_search'
      AND retail.r1b_adapter_is_certified_current(id) IS NOT TRUE
  ) THEN RAISE EXCEPTION 'G05 FAIL: stale certified adapter'; END IF;
  IF EXISTS (
    SELECT 1 FROM retail.retail_search_adapters
    WHERE certification_status='certified_dynamic_search'
      AND jsonb_array_length(supported_collection_methods)=0
      AND supports_all_collection_methods=false
  ) THEN RAISE EXCEPTION 'G06 FAIL: empty collection capability fail-open'; END IF;
  IF EXISTS (
    SELECT 1 FROM retail.retail_search_adapters
    WHERE certification_status='certified_dynamic_search'
      AND jsonb_array_length(supported_source_types)=0
      AND supports_all_source_types=false
  ) THEN RAISE EXCEPTION 'G07 FAIL: empty source capability fail-open'; END IF;
  IF EXISTS (
    SELECT 1 FROM retail.effective_search_routes r
    JOIN retail.search_locations l ON l.id=r.location_id
    WHERE l.location_status<>'approved'
  ) THEN RAISE EXCEPTION 'G08 FAIL: unapproved location effective'; END IF;
  IF EXISTS (
    SELECT 1 FROM retail.effective_search_routes r
    JOIN retail.search_locations l ON l.id=r.location_id
    WHERE l.location_type='store' AND l.platform_id<>r.platform_id
  ) THEN RAISE EXCEPTION 'G09 FAIL: cross-retailer store route'; END IF;
  IF EXISTS (
    SELECT 1 FROM retail.search_route_bindings r
    WHERE route_status='approved' AND retail.r1b_route_is_current(id) IS NOT TRUE
  ) THEN RAISE EXCEPTION 'G10 FAIL: approved route not current'; END IF;
END $$;

SELECT 'STATIC_ASSERTIONS_PASS' AS r1b_v3_static_result;
