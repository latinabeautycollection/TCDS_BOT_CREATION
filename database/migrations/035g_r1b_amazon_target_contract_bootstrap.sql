BEGIN;

SELECT set_config(
  'tcds.code_version',
  :'code_version',
  true
);

DO $$
DECLARE
  definition record;
  asset_record record;
  adapter_id uuid;
  contract_id uuid;
  process_run_id uuid;
  correlation_id text;
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

  FOR definition IN
    SELECT *
    FROM (
      VALUES
        (
          'amazon',
          'incoming/amazon/tcds-amazon-ingest',
          'amazon_brightdata_search',
          'AMAZON_KEYWORDS',
          'AMAZON_ZIPCODE',
          'AMAZON_LIMIT_PER_INPUT',
          'gd_l7q7dkf244hwjntr0',
          'retail.amazon_product_parsed'
        ),
        (
          'target',
          'incoming/target/tcds-target-brightdata-ingest',
          'target_brightdata_search',
          'TARGET_KEYWORDS',
          'TARGET_ZIPCODES',
          'TARGET_LIMIT_PER_INPUT',
          'gd_ltppk5mx2lp0v1k0vo',
          'retail.target_product_parsed'
        )
    ) AS definitions(
      platform_code,
      implementation_root,
      adapter_code,
      query_variable,
      postal_variable,
      limit_variable,
      dataset_id,
      parsed_table
    )
  LOOP
    SELECT
      platform.id AS platform_id,
      asset.id AS asset_id,
      asset.package_tree_sha256,
      asset.git_commit_sha
    INTO STRICT asset_record
    FROM retail.retail_platforms platform
    JOIN retail.retail_scraper_assets asset
      ON asset.platform_id = platform.id
    WHERE platform.platform_code = definition.platform_code
      AND asset.implementation_root =
          definition.implementation_root
      AND asset.implementation_authority_type = 'package_tree'
      AND asset.discovery_status = 'verified'
      AND asset.git_commit_sha =
          '0d97399e2b3a6fa4b1423168cf59780af1c0bb0c';

    SELECT adapter.id
    INTO adapter_id
    FROM retail.retail_search_adapters adapter
    WHERE adapter.platform_id = asset_record.platform_id
      AND adapter.adapter_code = definition.adapter_code
      AND adapter.adapter_version = '1';

    IF FOUND THEN
      RAISE EXCEPTION
        'Adapter already exists: % version 1',
        definition.adapter_code;
    END IF;

    correlation_id := gen_random_uuid()::text;

    INSERT INTO arb.process_runs(
      process_name,
      process_stage,
      status,
      correlation_id,
      actor_type,
      actor_id,
      actor_name,
      worker_name,
      worker_instance_id,
      code_version,
      ruleset_version,
      entity_type,
      idempotency_key
    )
    VALUES (
      'RETAIL_R1B_SCRAPER_CONTRACT_REGISTER',
      'EXECUTE',
      'STARTED',
      correlation_id,
      'user',
      'tictac',
      'Tictac R1B Contract Bootstrap',
      'r1b-amazon-target-contract-bootstrap',
      'r1b-v4-1',
      current_setting('tcds.code_version'),
      'r1b-v4.0.0',
      'retail.retail_scraper_contracts',
      'R1B:CONTRACT:' || definition.platform_code ||
        ':V1:0d97399'
    )
    RETURNING run_id INTO process_run_id;

    contract_json := jsonb_build_object(
      'contract_version', '1',
      'discovery_type', 'keyword',
      'transport', 'env',
      'compile_modes', jsonb_build_array('keyword'),
      'field_map', jsonb_build_object(
        'query', definition.query_variable,
        'postal_code', definition.postal_variable,
        'result_limit', definition.limit_variable
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
        jsonb_build_array(definition.dataset_id),
      'brightdata_unlocker_zones',
        jsonb_build_array(
          'tcds_web_unlocker',
          'tcds_premium_unlocker'
        ),
      'db_ingest_targets',
        jsonb_build_array(
          'retail.raw_product_captures',
          definition.parsed_table,
          'retail.retail_offer_snapshots',
          'retail.ingest_dead_letters'
        )
    );

    evidence_json := jsonb_build_object(
      'source_files', jsonb_build_array(
        definition.implementation_root || '/src/config.ts',
        definition.implementation_root || '/src/brightdata.ts',
        definition.implementation_root || '/src/index.ts',
        definition.implementation_root || '/src/db.ts'
      ),
      'verified_interface', jsonb_build_object(
        'keyword_transport', 'comma_separated_environment',
        'postal_transport',
          CASE
            WHEN definition.platform_code = 'amazon'
              THEN 'single_zip_applied_to_all_keywords'
            ELSE 'zip_list_positionally_paired_with_keywords'
          END,
        'result_limit_transport', 'environment_integer',
        'result_limit_minimum', 1,
        'result_limit_maximum', 1000
      ),
      'certification_limitations', jsonb_build_array(
        'No live location-specific QA has been completed',
        'Requested ZIP provenance requires worker remediation',
        CASE
          WHEN definition.platform_code = 'target'
            THEN 'Governed execution must use one keyword and one ZIP per invocation until positional ZIP handling is hardened'
          ELSE 'One configured ZIP applies to every keyword in the invocation'
        END
      ),
      'certification_scope',
        'Interface inventory only; not approved for execution'
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
      asset_record.platform_id,
      'search',
      definition.adapter_code,
      '1',
      definition.implementation_root,
      asset_record.package_tree_sha256,
      asset_record.git_commit_sha,
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
      '{}'::jsonb,
      'uncertified',
      'Tictac R1B Contract Bootstrap',
      asset_record.asset_id
    )
    RETURNING id INTO adapter_id;

    contract_id := retail.r1b_register_scraper_contract(
      asset_record.asset_id,
      adapter_id,
      '1',
      contract_json,
      evidence_json,
      process_run_id,
      correlation_id,
      'Tictac R1B Contract Bootstrap',
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
      'Registered % adapter %, contract %',
      definition.platform_code,
      adapter_id,
      contract_id;
  END LOOP;
END
$$;

COMMIT;
