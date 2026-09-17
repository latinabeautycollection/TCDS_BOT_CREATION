BEGIN;

SELECT set_config('tcds.code_version', :'code_version', true);

DO $$
DECLARE
  asset_row retail.retail_scraper_assets%ROWTYPE;
  adapter_id uuid;
  contract_id uuid;
  process_run_id uuid;
  correlation_id text := gen_random_uuid()::text;
  contract_json jsonb;
  evidence_json jsonb;
BEGIN
  IF NOT EXISTS (
    SELECT 1
    FROM retail.r1b_scraper_authority_state
    WHERE singleton
      AND hardening_version = '4.0.0'
  ) THEN
    RAISE EXCEPTION 'R1B scraper authority 4.0.0 is required';
  END IF;

  SELECT s.*
  INTO STRICT asset_row
  FROM retail.retail_scraper_assets s
  JOIN retail.retail_platforms p ON p.id = s.platform_id
  WHERE s.id = 'dbcba440-320f-41e8-bbd2-96cf4d8bd339'
    AND p.platform_code = 'kohls'
    AND s.implementation_root = 'incoming/kohls'
    AND s.implementation_authority_type = 'package_tree'
    AND s.discovery_status = 'verified'
    AND s.package_tree_sha256 =
      'bdc349c956e4d0b87a10b8398cc9fa24e86f3537a8555a131d1aa58895f948eb'
    AND s.git_commit_sha =
      '992a56943c9fb6aadb7d6e611892351f2559b255';

  IF EXISTS (
    SELECT 1
    FROM retail.retail_search_adapters
    WHERE platform_id = asset_row.platform_id
      AND adapter_code = 'kohls_brightdata_product_url'
      AND adapter_version = '1'
  ) THEN
    RAISE EXCEPTION 'Kohls product-URL adapter V1 already exists';
  END IF;

  IF NOT EXISTS (
    SELECT 1
    FROM retail.r1b_adapter_integration_matrix
    WHERE platform_id = asset_row.platform_id
      AND scraper_asset_id = asset_row.id
      AND r1b_certification_status = 'inventory_pending'
  ) THEN
    RAISE EXCEPTION 'Kohls inventory matrix is not pending';
  END IF;

  INSERT INTO arb.process_runs(
    process_name, process_stage, status, correlation_id,
    actor_type, actor_id, actor_name,
    worker_name, worker_instance_id, code_version,
    ruleset_version, entity_type, idempotency_key
  )
  VALUES (
    'RETAIL_R1B_SCRAPER_CONTRACT_REGISTER',
    'EXECUTE', 'STARTED', correlation_id,
    'user', 'tictac', 'Tictac R1B Kohls URL Authority',
    'r1b-kohls-product-url-register', 'r1b-v4-kohls-1',
    current_setting('tcds.code_version'),
    'r1b-v4.0.0',
    'retail.retail_scraper_contracts',
    'R1B:CONTRACT:kohls:PRODUCT_URL:V1:992a569'
  )
  RETURNING run_id INTO process_run_id;

  contract_json := jsonb_build_object(
    'contract_version', '1',
    'discovery_type', 'product_url',
    'transport', 'env',
    'compile_modes', jsonb_build_array('product_url'),
    'field_map', jsonb_build_object(
      'product_url', 'KOHLS_SEED_URLS',
      'result_limit', 'KOHLS_LIMIT_PER_INPUT'
    ),
    'required_fields',
      jsonb_build_array('product_url', 'result_limit'),
    'supports_keyword_search', false,
    'supports_category_search', false,
    'supports_product_url', true,
    'supports_store_id', false,
    'supports_postal_code', false,
    'supports_region', false,
    'supports_result_limit', true,
    'collection_methods',
      jsonb_build_array(
        'brightdata_dataset',
        'brightdata_unlocker'
      ),
    'source_types', jsonb_build_array('sale'),
    'brightdata_dataset_ids',
      jsonb_build_array('gd_mlji2hi729x1g0vg4i'),
    'brightdata_unlocker_zones',
      jsonb_build_array(
        'tcds_web_unlocker',
        'tcds_premium_unlocker'
      ),
    'db_ingest_targets',
      jsonb_build_array(
        'retail.raw_product_captures',
        'retail.kohls_product_parsed',
        'retail.retail_offer_snapshots',
        'retail.ingest_dead_letters'
      )
  );

  evidence_json := jsonb_build_object(
    'source_files', jsonb_build_array(
      'incoming/kohls/tcds-kohls-ingest/src/config.ts',
      'incoming/kohls/tcds-kohls-ingest/src/index.ts',
      'incoming/kohls/tcds-kohls-ingest/src/brightdata.ts',
      'incoming/kohls/tcds-kohls-ingest/src/db.ts'
    ),
    'verified_interface', jsonb_build_object(
      'url_variable', 'KOHLS_SEED_URLS',
      'url_scope', 'kohls.com',
      'url_transport', 'comma_separated_environment',
      'result_limit_variable', 'KOHLS_LIMIT_PER_INPUT',
      'result_limit_minimum', 1,
      'result_limit_maximum', 1000,
      'keyword_supported', false,
      'postal_code_supported', false,
      'store_id_supported', false
    ),
    'historical_ingest', jsonb_build_object(
      'collection_run_id',
        '1aa86d5a-a25a-4b48-8e15-b5d3e530fa34',
      'collected_rows', 40,
      'failed_rows', 0,
      'skipped_rows', 0,
      'raw_captures', 40,
      'parsed_rows', 40,
      'run_linked_offers', 40,
      'dead_letters', 0,
      'quality_events', 0
    ),
    'certification_limitations', jsonb_build_array(
      'Historical ingest is from July 2026, before the current asset inventory',
      'No package test script is present',
      'Fresh bounded QA is required before contract certification',
      'No ZIP, store-ID, or store-specific inventory capability is claimed',
      'Category seed URLs may work at runtime but are not certified as R1C category mode'
    ),
    'certification_scope',
      'Interface inventory only; not approved for R1 execution'
  );

  INSERT INTO retail.retail_search_adapters(
    platform_id, adapter_type, adapter_code, adapter_version,
    implementation_ref, implementation_sha256, git_commit_sha,
    supports_keyword_search, supports_product_url,
    supports_category_search, supports_store_id,
    supports_postal_code, supports_region,
    supports_result_limit,
    supported_collection_methods,
    supports_all_collection_methods,
    supported_source_types,
    supports_all_source_types,
    input_contract_json, capability_json,
    certification_status, created_by, scraper_asset_id
  )
  VALUES (
    asset_row.platform_id,
    'search',
    'kohls_brightdata_product_url',
    '1',
    asset_row.implementation_root,
    asset_row.package_tree_sha256,
    asset_row.git_commit_sha,
    false, true, false, false, false, false, true,
    jsonb_build_array(
      'brightdata_dataset',
      'brightdata_unlocker'
    ),
    false,
    jsonb_build_array('sale'),
    false,
    jsonb_build_object(
      'transport', 'env',
      'compile_modes', jsonb_build_array('product_url'),
      'field_map', contract_json->'field_map',
      'required_fields', contract_json->'required_fields'
    ),
    jsonb_build_object(
      'location_scope', 'national_online',
      'store_id_supported', false,
      'postal_code_supported', false
    ),
    'uncertified',
    'Tictac R1B Kohls URL Authority',
    asset_row.id
  )
  RETURNING id INTO adapter_id;

  contract_id := retail.r1b_register_scraper_contract(
    asset_row.id,
    adapter_id,
    '1',
    contract_json,
    evidence_json,
    process_run_id,
    correlation_id,
    'Tictac R1B Kohls URL Authority',
    NULL
  );

  UPDATE arb.process_runs
  SET status = 'SUCCEEDED',
      rows_seen = 1,
      rows_succeeded = 1,
      rows_failed = 0,
      completed_at = now(),
      updated_at = now()
  WHERE run_id = process_run_id;

  RAISE NOTICE
    'Registered Kohls adapter %, contract %',
    adapter_id, contract_id;
END
$$;

COMMIT;
