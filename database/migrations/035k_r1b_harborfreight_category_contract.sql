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
  WHERE s.id = 'e9e1fc56-3b92-4720-9266-228e8ebac20d'
    AND p.platform_code = 'harborfreight'
    AND s.implementation_root = 'incoming/harborfreight'
    AND s.implementation_authority_type = 'package_tree'
    AND s.discovery_status = 'verified'
    AND s.package_tree_sha256 =
      'ca819ec5e7fdb63a4459ff361fc9bdf3130c69c8a00d21d8d4a7e99be3545b08'
    AND s.git_commit_sha =
      '992a56943c9fb6aadb7d6e611892351f2559b255';

  IF EXISTS (
    SELECT 1
    FROM retail.retail_search_adapters
    WHERE platform_id = asset_row.platform_id
      AND adapter_code = 'harborfreight_brightdata_category'
      AND adapter_version = '1'
  ) THEN
    RAISE EXCEPTION 'Harbor Freight category-URL adapter V1 already exists';
  END IF;

  IF NOT EXISTS (
    SELECT 1
    FROM retail.r1b_adapter_integration_matrix
    WHERE platform_id = asset_row.platform_id
      AND scraper_asset_id = asset_row.id
      AND r1b_certification_status = 'inventory_pending'
  ) THEN
    RAISE EXCEPTION 'Harbor Freight inventory matrix is not pending';
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
    'user', 'tictac', 'Tictac R1B Harbor Freight URL Authority',
    'r1b-harborfreight-product-url-register', 'r1b-v4-harborfreight-1',
    current_setting('tcds.code_version'),
    'r1b-v4.0.0',
    'retail.retail_scraper_contracts',
    'R1B:CONTRACT:harborfreight:CATEGORY:V1:992a569'
  )
  RETURNING run_id INTO process_run_id;

  contract_json := jsonb_build_object(
    'contract_version', '1',
    'discovery_type', 'category',
    'transport', 'env',
    'compile_modes', jsonb_build_array('category'),
    'field_map', jsonb_build_object(
      'category', 'HARBORFREIGHT_SEED_URLS',
      'result_limit', 'HARBORFREIGHT_LIMIT_PER_INPUT'
    ),
    'required_fields',
      jsonb_build_array('category', 'result_limit'),
    'supports_keyword_search', false,
    'supports_category_search', true,
    'supports_product_url', false,
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
      jsonb_build_array('gd_mky1qkjbnsea4buxc'),
    'brightdata_unlocker_zones',
      jsonb_build_array(
        'tcds_web_unlocker',
        'tcds_premium_unlocker'
      ),
    'db_ingest_targets',
      jsonb_build_array(
        'retail.raw_product_captures',
        'retail.harborfreight_product_parsed',
        'retail.retail_offer_snapshots',
        'retail.ingest_dead_letters'
      )
  );

  evidence_json := jsonb_build_object(
    'source_files', jsonb_build_array(
      'incoming/harborfreight/tcds-harborfreight-ingest/src/config.ts',
      'incoming/harborfreight/tcds-harborfreight-ingest/src/index.ts',
      'incoming/harborfreight/tcds-harborfreight-ingest/src/brightdata.ts',
      'incoming/harborfreight/tcds-harborfreight-ingest/src/db.ts'
    ),
    'verified_interface', jsonb_build_object(
      'category_variable', 'HARBORFREIGHT_SEED_URLS',
      'category_scope', 'harborfreight.com category URLs',
      'category_transport', 'comma_separated_environment',
      'result_limit_variable', 'HARBORFREIGHT_LIMIT_PER_INPUT',
      'result_limit_minimum', 1,
      'result_limit_maximum', 1000,
      'keyword_supported', false,
      'postal_code_supported', false,
      'store_id_supported', false
    ),
    'historical_ingest', jsonb_build_object(
      'collection_run_id',
        '39b354aa-23fd-472a-9546-cab7d4f5efc4',
      'collected_rows', 50,
      'failed_rows', 0,
      'skipped_rows', 0,
      'raw_captures', 50,
      'parsed_rows', 50,
      'run_linked_offers', 50,
      'dead_letters', 0,
      'quality_events', 54
    ),
    'certification_limitations', jsonb_build_array(
      'Historical ingest is from July 2026, before the current asset inventory',
      'Package typecheck, build, and two tests passed',
      'Fresh bounded QA is required before contract certification',
      'No ZIP, store-ID, or store-specific inventory capability is claimed',
      'Category URL is the only certified R1C compile mode'
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
    'harborfreight_brightdata_category',
    '1',
    asset_row.implementation_root,
    asset_row.package_tree_sha256,
    asset_row.git_commit_sha,
    false, false, true, false, false, false, true,
    jsonb_build_array(
      'brightdata_dataset',
      'brightdata_unlocker'
    ),
    false,
    jsonb_build_array('sale'),
    false,
    jsonb_build_object(
      'transport', 'env',
      'compile_modes', jsonb_build_array('category'),
      'field_map', contract_json->'field_map',
      'required_fields', contract_json->'required_fields'
    ),
    jsonb_build_object(
      'location_scope', 'national_online',
      'store_id_supported', false,
      'postal_code_supported', false
    ),
    'uncertified',
    'Tictac R1B Harbor Freight URL Authority',
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
    'Tictac R1B Harbor Freight URL Authority',
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
    'Registered Harbor Freight adapter %, contract %',
    adapter_id, contract_id;
END
$$;

COMMIT;
