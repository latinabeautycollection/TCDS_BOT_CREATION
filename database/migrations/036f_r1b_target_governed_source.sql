BEGIN;

DO $$
DECLARE
  v_count bigint;
BEGIN
  IF NOT EXISTS (
    SELECT 1
    FROM retail.r1b_schema_state
    WHERE singleton
      AND schema_version = '3.0.0'
  ) THEN
    RAISE EXCEPTION 'R1B schema 3.0.0 is required';
  END IF;

  IF retail.r1b_r1a_binding_is_current() IS DISTINCT FROM true THEN
    RAISE EXCEPTION 'Current certified R1A binding is required';
  END IF;

  SELECT count(*) INTO v_count
  FROM retail.retail_platforms
  WHERE id = 'c0515b32-89e1-4ac4-b767-ed50df8cb433'
    AND platform_code = 'target'
    AND status = 'active';

  IF v_count <> 1 THEN
    RAISE EXCEPTION 'Exactly one expected active Target platform is required';
  END IF;

  SELECT count(*) INTO v_count
  FROM retail.retail_search_adapters
  WHERE id = 'c6a5071a-121e-4a1c-8fa6-e31971976840'
    AND adapter_code = 'target_brightdata_search'
    AND adapter_version = '2'
    AND implementation_sha256 =
      'e8b241399bc573d0d1535faa6d44b03f7edd20af2bb5ae72e203a1188d264537'
    AND capability_sha256 =
      '8f36b97be9294a8e8e67e3f5c51736c0348380b64e8f5ab0fc907f3e7d55bf17'
    AND certification_status = 'certified_dynamic_search'
    AND supports_keyword_search
    AND supports_postal_code
    AND supports_result_limit
    AND retail.r1b_adapter_execution_ready(id);

  IF v_count <> 1 THEN
    RAISE EXCEPTION 'Expected certified Target v2 adapter is unavailable';
  END IF;

  SELECT count(*) INTO v_count
  FROM retail.collection_runs
  WHERE id = '00fe3dfe-9672-48a9-93fe-0903945bcb08'
    AND status = 'completed'
    AND total_requested = 2
    AND total_collected = 2
    AND total_failed = 0
    AND total_skipped = 0
    AND run_metadata->>'dataset_id' = 'gd_ltppk5mx2lp0v1k0vo'
    AND run_metadata->>'snapshot_id' = 'sd_mu4bt1tj2g7ufq6zgw';

  IF v_count <> 1 THEN
    RAISE EXCEPTION 'Target QA collection run did not pass';
  END IF;

  SELECT count(*) INTO v_count
  FROM retail.raw_product_captures
  WHERE collection_run_id = '00fe3dfe-9672-48a9-93fe-0903945bcb08';

  IF v_count <> 2 THEN
    RAISE EXCEPTION 'Target QA raw-capture count must equal 2';
  END IF;

  SELECT count(*) INTO v_count
  FROM retail.target_product_parsed
  WHERE collection_run_id = '00fe3dfe-9672-48a9-93fe-0903945bcb08';

  IF v_count <> 2 THEN
    RAISE EXCEPTION 'Target QA parsed-row count must equal 2';
  END IF;

  SELECT count(*) INTO v_count
  FROM retail.ingest_dead_letters
  WHERE collection_run_id = '00fe3dfe-9672-48a9-93fe-0903945bcb08';

  IF v_count <> 0 THEN
    RAISE EXCEPTION 'Target QA run contains dead letters';
  END IF;

  SELECT count(*) INTO v_count
  FROM retail.data_quality_events
  WHERE event_json->>'run_id' = '00fe3dfe-9672-48a9-93fe-0903945bcb08';

  IF v_count <> 0 THEN
    RAISE EXCEPTION 'Target QA run contains quality events';
  END IF;
END
$$;

WITH platform AS (
  SELECT id
  FROM retail.retail_platforms
  WHERE id = 'c0515b32-89e1-4ac4-b767-ed50df8cb433'
    AND platform_code = 'target'
    AND status = 'active'
),
config AS (
  INSERT INTO retail.platform_collection_configs (
    platform_id,
    config_name,
    is_active,
    collection_strategy,
    category_seed_json,
    search_seed_json,
    request_policy_json,
    parser_policy_json,
    evidence_policy_json,
    source_policy_mode,
    discount_policy_version,
    reject_unqualified_products
  )
  SELECT
    platform.id,
    'Target R1B governed keyword discovery v1',
    true,
    'r1a_targeted_keyword_discovery_with_dataset_and_unlocker_fallback',
    '[]'::jsonb,
    '[]'::jsonb,
    jsonb_build_object(
      'authority', 'R1B',
      'input_authority', 'retail.effective_search_targets',
      'dataset_id', 'gd_ltppk5mx2lp0v1k0vo',
      'discovery_method', 'brightdata_dataset',
      'discover_by', 'keywords',
      'fallback_method', 'brightdata_unlocker',
      'result_limit_supported', true,
      'postal_code_supported', true,
      'approved_sources_only', true
    ),
    jsonb_build_object(
      'parser', 'target_brightdata_v2',
      'unlocker_fallback', 'evidence_only',
      'qualification_authority', 'R1E'
    ),
    jsonb_build_object(
      'qa_evidence',
        'evidence/retail-automation/r1b/target-v2-location-qa.json',
      'qa_evidence_sha256',
        'dd1ba33dae2397ce8339580257aac1116e592fdbf6fbe515da310032ded24347',
      'qa_run_id',
        '00fe3dfe-9672-48a9-93fe-0903945bcb08',
      'qa_snapshot_id',
        'sd_mu4bt1tj2g7ufq6zgw',
      'location_evidence', 'requested_postal_code',
      'store_identity_proven', false
    ),
    'approved_sources_only',
    'r1e_pending',
    true
  FROM platform
  ON CONFLICT (platform_id, config_name)
  DO UPDATE SET
    is_active = excluded.is_active,
    collection_strategy = excluded.collection_strategy,
    category_seed_json = excluded.category_seed_json,
    search_seed_json = excluded.search_seed_json,
    request_policy_json = excluded.request_policy_json,
    parser_policy_json = excluded.parser_policy_json,
    evidence_policy_json = excluded.evidence_policy_json,
    source_policy_mode = excluded.source_policy_mode,
    discount_policy_version = excluded.discount_policy_version,
    reject_unqualified_products = excluded.reject_unqualified_products,
    updated_at = now()
  RETURNING id, platform_id
)
INSERT INTO retail.platform_collection_sources (
  platform_id,
  config_id,
  source_code,
  source_name,
  source_url,
  source_type,
  source_scope,
  collection_method,
  dataset_id,
  unlocker_zone,
  required_postal_code,
  is_approved,
  is_active,
  maximum_effective_price,
  pagination_policy,
  request_overrides,
  qualification_policy,
  verified_http_status,
  verified_final_url,
  last_verified_at,
  last_successful_collection_at,
  created_by,
  approved_by,
  approved_at
)
SELECT
  config.platform_id,
  config.id,
  'target_keyword_national',
  'Target governed national keyword discovery',
  'https://www.target.com/s',
  'sale',
  'national',
  'brightdata_dataset',
  'gd_ltppk5mx2lp0v1k0vo',
  'tcds_web_unlocker',
  null,
  true,
  true,
  500.00,
  jsonb_build_object(
    'mode', 'result_limit',
    'default_limit', 100
  ),
  jsonb_build_object(
    'keyword_source', 'retail.effective_search_targets',
    'postal_code_field', 'TARGET_ZIPCODES',
    'manual_keyword_override', 'qa_only',
    'fallback_collection_method', 'brightdata_unlocker'
  ),
  jsonb_build_object(
    'identity_gate', 'R1E',
    'condition_gate', 'R1E',
    'price_gate', 'R1E',
    'reject_unqualified_products', true
  ),
  200,
  'https://www.target.com/s',
  now(),
  (
    SELECT max(captured_at)
    FROM retail.raw_product_captures
    WHERE collection_run_id =
      '00fe3dfe-9672-48a9-93fe-0903945bcb08'
  ),
  'tictac',
  'tictac',
  now()
FROM config
ON CONFLICT (platform_id, source_code)
DO UPDATE SET
  config_id = excluded.config_id,
  source_name = excluded.source_name,
  source_url = excluded.source_url,
  source_type = excluded.source_type,
  source_scope = excluded.source_scope,
  collection_method = excluded.collection_method,
  dataset_id = excluded.dataset_id,
  unlocker_zone = excluded.unlocker_zone,
  required_postal_code = excluded.required_postal_code,
  is_approved = excluded.is_approved,
  is_active = excluded.is_active,
  maximum_effective_price = excluded.maximum_effective_price,
  pagination_policy = excluded.pagination_policy,
  request_overrides = excluded.request_overrides,
  qualification_policy = excluded.qualification_policy,
  verified_http_status = excluded.verified_http_status,
  verified_final_url = excluded.verified_final_url,
  last_verified_at = excluded.last_verified_at,
  last_successful_collection_at = excluded.last_successful_collection_at,
  approved_by = excluded.approved_by,
  approved_at = excluded.approved_at,
  updated_at = now();

COMMIT;
