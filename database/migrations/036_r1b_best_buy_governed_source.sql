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
  WHERE platform_code = 'best_buy'
    AND status = 'active';

  IF v_count <> 1 THEN
    RAISE EXCEPTION 'Exactly one active best_buy platform is required';
  END IF;

  SELECT count(*) INTO v_count
  FROM retail.retail_search_adapters
  WHERE id = '2e4f0f6b-32f5-4d15-84d7-76ddd2aa401a'
    AND adapter_code = 'bestbuy_brightdata_search'
    AND adapter_version = '2'
    AND implementation_sha256 =
      '69248ce08ff890335c6532cc5382c4d54c765c23b393518264312f524d3dd662'
    AND certification_status = 'partially_dynamic'
    AND supports_keyword_search
    AND supports_product_url
    AND supports_result_limit;

  IF v_count <> 1 THEN
    RAISE EXCEPTION 'Expected inventoried Best Buy v2 adapter is unavailable';
  END IF;

  SELECT count(*) INTO v_count
  FROM retail.collection_runs
  WHERE id = '3a39c1d7-9260-4182-9057-0ecd254e83c1'
    AND status = 'completed'
    AND total_requested = 10
    AND total_collected = 10
    AND total_failed = 0
    AND total_skipped = 0;

  IF v_count <> 1 THEN
    RAISE EXCEPTION 'Best Buy QA collection run did not pass';
  END IF;

  SELECT count(*) INTO v_count
  FROM retail.raw_product_captures
  WHERE collection_run_id =
    '3a39c1d7-9260-4182-9057-0ecd254e83c1';

  IF v_count <> 10 THEN
    RAISE EXCEPTION 'Best Buy QA raw-capture count must equal 10';
  END IF;

  SELECT count(*) INTO v_count
  FROM retail.bestbuy_product_parsed
  WHERE collection_run_id =
    '3a39c1d7-9260-4182-9057-0ecd254e83c1';

  IF v_count <> 10 THEN
    RAISE EXCEPTION 'Best Buy QA parsed-row count must equal 10';
  END IF;

  SELECT count(*) INTO v_count
  FROM retail.ingest_dead_letters
  WHERE collection_run_id =
    '3a39c1d7-9260-4182-9057-0ecd254e83c1';

  IF v_count <> 0 THEN
    RAISE EXCEPTION 'Best Buy QA run contains dead letters';
  END IF;

  SELECT count(*) INTO v_count
  FROM retail.data_quality_events
  WHERE event_json->>'run_id' =
    '3a39c1d7-9260-4182-9057-0ecd254e83c1';

  IF v_count <> 0 THEN
    RAISE EXCEPTION 'Best Buy QA run contains quality events';
  END IF;

  SELECT count(*) INTO v_count
  FROM retail.raw_product_captures
  WHERE collection_run_id =
      '3a39c1d7-9260-4182-9057-0ecd254e83c1'
    AND raw_payload->>'sku' IS NOT NULL
    AND substring(
      coalesce(raw_payload->>'url', raw_payload->>'product_url')
      FROM '/sku/([0-9]+)'
    ) IS NOT NULL
    AND raw_payload->>'sku' <> substring(
      coalesce(raw_payload->>'url', raw_payload->>'product_url')
      FROM '/sku/([0-9]+)'
    );

  IF v_count <> 0 THEN
    RAISE EXCEPTION 'Best Buy QA run contains SKU/URL mismatches';
  END IF;
END
$$;

WITH platform AS (
  SELECT id
  FROM retail.retail_platforms
  WHERE platform_code = 'best_buy'
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
    'Best Buy R1B governed targeted search v1',
    true,
    'r1a_targeted_keyword_discovery_with_unlocker_and_dataset_detail',
    '[]'::jsonb,
    '[]'::jsonb,
    jsonb_build_object(
      'authority', 'R1B',
      'input_authority', 'retail.effective_search_targets',
      'dataset_id', 'gd_ltre1jqe1jfr7cccf',
      'discovery_method', 'brightdata_unlocker',
      'detail_method', 'brightdata_dataset',
      'result_limit_supported', true,
      'approved_sources_only', true
    ),
    jsonb_build_object(
      'parser', 'bestbuy_brightdata_v2',
      'sku_url_integrity', 'fail_closed',
      'qualification_authority', 'R1E'
    ),
    jsonb_build_object(
      'qa_evidence',
        'evidence/retail-automation/r1b/bestbuy-v2-qa.json',
      'qa_evidence_sha256',
        'bc5f13efd8429ee5b3e1b1db58d0f682f75ebb69014349b453df09d0cfae0b96',
      'qa_run_id',
        '3a39c1d7-9260-4182-9057-0ecd254e83c1',
      'qa_snapshot_id',
        'sd_mtypprfp1beo37d3vk'
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
  'best_buy_targeted_sale_national',
  'Best Buy governed targeted national sale search',
  'https://www.bestbuy.com/site/searchpage.jsp',
  'sale',
  'national',
  'brightdata_unlocker',
  'gd_ltre1jqe1jfr7cccf',
  'tcds_web_unlocker',
  true,
  true,
  500.00,
  jsonb_build_object(
    'mode', 'result_limit',
    'default_limit', 50
  ),
  jsonb_build_object(
    'detail_collection_method', 'brightdata_dataset',
    'keyword_source', 'retail.effective_search_targets',
    'manual_url_override', 'qa_only'
  ),
  jsonb_build_object(
    'identity_gate', 'R1E',
    'condition_gate', 'R1E',
    'price_gate', 'R1E',
    'reject_unqualified_products', true
  ),
  200,
  'https://www.bestbuy.com/site/searchpage.jsp',
  now(),
  (
    SELECT max(captured_at)
    FROM retail.raw_product_captures
    WHERE collection_run_id =
      '3a39c1d7-9260-4182-9057-0ecd254e83c1'
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
  is_approved = excluded.is_approved,
  is_active = excluded.is_active,
  maximum_effective_price = excluded.maximum_effective_price,
  pagination_policy = excluded.pagination_policy,
  request_overrides = excluded.request_overrides,
  qualification_policy = excluded.qualification_policy,
  verified_http_status = excluded.verified_http_status,
  verified_final_url = excluded.verified_final_url,
  last_verified_at = excluded.last_verified_at,
  last_successful_collection_at =
    excluded.last_successful_collection_at,
  approved_by = excluded.approved_by,
  approved_at = excluded.approved_at,
  updated_at = now();

COMMIT;
