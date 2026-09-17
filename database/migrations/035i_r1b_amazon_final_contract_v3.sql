BEGIN;

SELECT set_config('tcds.code_version', :'code_version', true);

DO $$
DECLARE
  final_asset record;
  prior_adapter_id uuid;
  prior_contract_id uuid;
  adapter_id uuid;
  contract_id uuid;
  block_run_id uuid;
  register_run_id uuid;
  correlation_id text;
  contract_json jsonb;
  evidence_json jsonb;
  qa_run constant uuid :=
    'e6764287-daaf-4a4f-8158-172b0d50fe81';
BEGIN
  IF NOT EXISTS (
    SELECT 1
    FROM retail.r1b_scraper_authority_state
    WHERE singleton
      AND hardening_version = '4.0.0'
  ) THEN
    RAISE EXCEPTION 'R1B scraper authority 4.0.0 is required';
  END IF;

  SELECT
    s.id,
    s.platform_id,
    s.implementation_root,
    s.package_tree_sha256,
    s.git_commit_sha,
    s.verification_evidence_sha256
  INTO STRICT final_asset
  FROM retail.retail_scraper_assets s
  JOIN retail.retail_platforms p ON p.id = s.platform_id
  WHERE p.platform_code = 'amazon'
    AND s.id = 'e0445442-080c-4d7d-8c4e-105d271cb041'
    AND s.implementation_root =
        'incoming/amazon/tcds-amazon-ingest'
    AND s.implementation_authority_type = 'package_tree'
    AND s.discovery_status = 'verified'
    AND s.package_tree_sha256 =
        '3f02ff894985065658f24cffe2c012fb7b8070a8ad95821bdd1cf4abc7f65b0f'
    AND s.git_commit_sha =
        'c1397e5cbfa0be314aa203d86cef2d7ca7113ffd';

  IF NOT EXISTS (
    SELECT 1
    FROM retail.collection_runs r
    WHERE r.id = qa_run
      AND r.status = 'completed'
      AND r.total_collected = 2
      AND r.total_failed = 0
      AND r.total_skipped = 0
      AND r.run_metadata->>'requested_zipcode' = '10001'
  ) THEN
    RAISE EXCEPTION 'Final Amazon QA run is missing or invalid';
  END IF;

  IF (
    SELECT count(*)
    FROM retail.raw_product_captures rc
    WHERE rc.collection_run_id = qa_run
      AND rc.capture_metadata->>'requested_zipcode' = '10001'
      AND rc.capture_metadata->>'observed_zipcode' IS NOT NULL
  ) <> 2 THEN
    RAISE EXCEPTION 'Amazon QA ZIP provenance assertion failed';
  END IF;

  IF (
    SELECT count(*)
    FROM retail.amazon_product_parsed p
    WHERE p.collection_run_id = qa_run
  ) <> 2 THEN
    RAISE EXCEPTION 'Amazon QA parsed-row assertion failed';
  END IF;

  IF EXISTS (
    SELECT 1
    FROM retail.ingest_dead_letters d
    WHERE d.collection_run_id = qa_run
  ) THEN
    RAISE EXCEPTION 'Amazon QA contains dead letters';
  END IF;

  SELECT a.id, c.id
  INTO STRICT prior_adapter_id, prior_contract_id
  FROM retail.retail_search_adapters a
  JOIN retail.retail_scraper_contracts c
    ON c.id = a.scraper_contract_id
   AND c.adapter_id = a.id
   AND c.scraper_asset_id = a.scraper_asset_id
  WHERE a.platform_id = final_asset.platform_id
    AND a.adapter_code = 'amazon_brightdata_search'
    AND a.adapter_version = '2'
    AND a.certification_status = 'uncertified'
    AND c.contract_version = '2'
    AND c.certification_status = 'inventory_pending'
    AND a.scraper_asset_id <> final_asset.id;

  IF EXISTS (
    SELECT 1
    FROM retail.retail_search_adapters
    WHERE platform_id = final_asset.platform_id
      AND adapter_code = 'amazon_brightdata_search'
      AND adapter_version = '3'
  ) THEN
    RAISE EXCEPTION 'Amazon adapter version 3 already exists';
  END IF;

  correlation_id := gen_random_uuid()::text;

  INSERT INTO arb.process_runs(
    process_name, process_stage, status, correlation_id,
    actor_type, actor_id, actor_name,
    worker_name, worker_instance_id, code_version,
    ruleset_version, entity_type, idempotency_key
  )
  VALUES (
    'RETAIL_R1B_SCRAPER_CONTRACT_BLOCK',
    'EXECUTE', 'STARTED', correlation_id,
    'user', 'tictac', 'Tictac',
    'r1b-amazon-v2-supersession', 'r1b-v4-3',
    current_setting('tcds.code_version'),
    'r1b-v4.0.0',
    'retail.retail_scraper_contracts',
    'R1B:AMAZON:V2:SUPERSEDED:' || correlation_id
  )
  RETURNING run_id INTO block_run_id;

  PERFORM retail.r1b_transition_scraper_contract(
    prior_contract_id,
    'blocked',
    block_run_id,
    correlation_id,
    'tictac',
    'Superseded by Amazon V3 final QA-qualified implementation'
  );

  PERFORM set_config('app.actor_type', 'user', true);
  PERFORM set_config('app.actor_name', 'tictac', true);
  PERFORM set_config(
    'app.process_run_id',
    block_run_id::text,
    true
  );
  PERFORM set_config(
    'app.correlation_id',
    correlation_id,
    true
  );

  UPDATE retail.retail_search_adapters
  SET certification_status = 'suspended',
      suspended_reason =
        'Superseded by Amazon V3 final QA-qualified implementation',
      updated_at = now()
  WHERE id = prior_adapter_id
    AND certification_status = 'uncertified';

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Amazon V2 adapter was not suspended';
  END IF;

  UPDATE arb.process_runs
  SET status = 'SUCCEEDED',
      rows_seen = 1,
      rows_succeeded = 1,
      rows_failed = 0,
      completed_at = now(),
      updated_at = now()
  WHERE run_id = block_run_id;

  correlation_id := gen_random_uuid()::text;

  INSERT INTO arb.process_runs(
    process_name, process_stage, status, correlation_id,
    actor_type, actor_id, actor_name,
    worker_name, worker_instance_id, code_version,
    ruleset_version, entity_type, idempotency_key
  )
  VALUES (
    'RETAIL_R1B_SCRAPER_CONTRACT_REGISTER',
    'EXECUTE', 'STARTED', correlation_id,
    'user', 'tictac', 'Tictac R1B Amazon V3 Authority',
    'r1b-amazon-final-contract-v3', 'r1b-v4-3',
    current_setting('tcds.code_version'),
    'r1b-v4.0.0',
    'retail.retail_scraper_contracts',
    'R1B:CONTRACT:amazon:V3:c1397e5'
  )
  RETURNING run_id INTO register_run_id;

  contract_json := jsonb_build_object(
    'contract_version', '3',
    'discovery_type', 'keyword',
    'transport', 'env',
    'compile_modes', jsonb_build_array('keyword'),
    'field_map', jsonb_build_object(
      'query', 'AMAZON_KEYWORDS',
      'postal_code', 'AMAZON_ZIPCODE',
      'result_limit', 'AMAZON_LIMIT_PER_INPUT'
    ),
    'required_fields',
      jsonb_build_array('query', 'result_limit'),
    'supports_keyword_search', true,
    'supports_category_search', false,
    'supports_product_url', false,
    'supports_store_id', false,
    'supports_postal_code', true,
    'supports_region', false,
    'supports_result_limit', true,
    'collection_methods',
      jsonb_build_array(
        'brightdata_dataset',
        'brightdata_unlocker'
      ),
    'source_types', jsonb_build_array('sale'),
    'brightdata_dataset_ids',
      jsonb_build_array('gd_l7q7dkf244hwjntr0'),
    'brightdata_unlocker_zones',
      jsonb_build_array(
        'tcds_web_unlocker',
        'tcds_premium_unlocker'
      ),
    'db_ingest_targets',
      jsonb_build_array(
        'retail.raw_product_captures',
        'retail.amazon_product_parsed',
        'retail.retail_offer_snapshots',
        'retail.ingest_dead_letters'
      )
  );

  evidence_json := jsonb_build_object(
    'asset', jsonb_build_object(
      'scraper_asset_id', final_asset.id,
      'implementation_root', final_asset.implementation_root,
      'package_tree_sha256', final_asset.package_tree_sha256,
      'git_commit_sha', final_asset.git_commit_sha,
      'verification_evidence_sha256',
        final_asset.verification_evidence_sha256
    ),
    'verified_interface', jsonb_build_object(
      'keyword_transport', 'comma_separated_environment',
      'postal_transport',
        'single_zip_applied_to_all_keywords',
      'result_limit_transport', 'environment_integer',
      'result_limit_minimum', 1,
      'result_limit_maximum', 1000
    ),
    'live_qa', jsonb_build_object(
      'collection_run_id', qa_run,
      'requested_postal_code', '10001',
      'requested_inputs', 1,
      'collected_rows', 2,
      'failed_rows', 0,
      'skipped_rows', 0,
      'raw_captures', 2,
      'requested_zip_captures', 2,
      'observed_zip_captures', 2,
      'parsed_rows', 2,
      'dead_letters', 0
    ),
    'certification_limitations', jsonb_build_array(
      'QA is bounded to one keyword and one requested ZIP code',
      'Postal-code support does not prove retailer store-ID support',
      'One configured ZIP applies to every keyword in an invocation'
    ),
    'certification_scope',
      'Bounded live postal-code QA passed; lifecycle and adapter certification remain required'
  );

  INSERT INTO retail.retail_search_adapters(
    platform_id,
    adapter_type,
    adapter_code,
    adapter_version,
    implementation_ref,
    implementation_sha256,
    git_commit_sha,
    supports_keyword_search,
    supports_product_url,
    supports_category_search,
    supports_store_id,
    supports_postal_code,
    supports_region,
    supports_result_limit,
    supported_collection_methods,
    supports_all_collection_methods,
    supported_source_types,
    supports_all_source_types,
    input_contract_json,
    capability_json,
    certification_status,
    created_by,
    scraper_asset_id
  )
  VALUES (
    final_asset.platform_id,
    'search',
    'amazon_brightdata_search',
    '3',
    final_asset.implementation_root,
    final_asset.package_tree_sha256,
    final_asset.git_commit_sha,
    true,
    false,
    false,
    false,
    true,
    false,
    true,
    jsonb_build_array(
      'brightdata_dataset',
      'brightdata_unlocker'
    ),
    false,
    jsonb_build_array('sale'),
    false,
    jsonb_build_object(
      'transport', 'env',
      'compile_modes', jsonb_build_array('keyword'),
      'field_map', contract_json->'field_map',
      'required_fields', contract_json->'required_fields'
    ),
    jsonb_build_object(
      'location_scope', 'requested_postal_code',
      'store_id_supported', false,
      'live_qa_run_id', qa_run
    ),
    'uncertified',
    'Tictac R1B Amazon V3 Authority',
    final_asset.id
  )
  RETURNING id INTO adapter_id;

  contract_id := retail.r1b_register_scraper_contract(
    final_asset.id,
    adapter_id,
    '3',
    contract_json,
    evidence_json,
    register_run_id,
    correlation_id,
    'Tictac R1B Amazon V3 Authority',
    prior_contract_id
  );

  UPDATE arb.process_runs
  SET status = 'SUCCEEDED',
      rows_seen = 1,
      rows_succeeded = 1,
      rows_failed = 0,
      completed_at = now(),
      updated_at = now()
  WHERE run_id = register_run_id;

  RAISE NOTICE
    'Registered Amazon V3 adapter %, contract %',
    adapter_id,
    contract_id;
END
$$;

COMMIT;
