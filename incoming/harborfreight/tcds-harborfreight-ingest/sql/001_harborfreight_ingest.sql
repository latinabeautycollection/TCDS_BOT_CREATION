BEGIN;

-- Reuse existing enum values without hard-coding user-defined enum casts.
INSERT INTO retail.retail_platforms(
  platform_code,platform_name,base_url,access_type,status,priority_rank,
  is_purchase_supported,is_data_collection_supported,max_daily_requests,max_hourly_requests,
  robots_policy_url,terms_url,governance_notes
)
SELECT
  'harborfreight','Harbor Freight','https://www.harborfreight.com',access_type,status,40,
  true,true,5000,500,
  'https://www.harborfreight.com/robots.txt','https://www.harborfreight.com/terms-and-conditions',
  'Bright Data Harbor Freight dataset gd_mky1qkjbnsea4buxc is the primary collector. Web Unlocker zones tcds_web_unlocker and tcds_premium_unlocker are controlled fallback/evidence paths.'
FROM retail.retail_platforms
ORDER BY created_at
LIMIT 1
ON CONFLICT(platform_code) DO UPDATE SET
  platform_name=EXCLUDED.platform_name,
  base_url=EXCLUDED.base_url,
  is_data_collection_supported=true,
  governance_notes=EXCLUDED.governance_notes,
  updated_at=now();

DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM retail.retail_platforms WHERE platform_code='harborfreight') THEN
    RAISE EXCEPTION 'Cannot seed Harbor Freight: retail.retail_platforms has no row from which enum values can be copied';
  END IF;
END $$;

INSERT INTO retail.platform_collection_configs(
  platform_id,config_name,is_active,schedule_cron,collection_strategy,
  category_seed_json,search_seed_json,request_policy_json,parser_policy_json,evidence_policy_json
)
SELECT id,'Harbor Freight Bright Data tools and automotive ingest v1',true,NULL,'dataset_category_url_discovery_with_unlocker_fallback',
  '[{"url":"https://www.harborfreight.com/power-tools/drills-drivers.html","category":"drills_drivers"},{"url":"https://www.harborfreight.com/automotive/diagnostic-testing-scanning.html","category":"diagnostic_testing_scanning"},{"url":"https://www.harborfreight.com/automotive/battery-tools-accessories.html","category":"battery_tools_accessories"}]'::jsonb,
  '[]'::jsonb,
  '{"dataset_id":"gd_mky1qkjbnsea4buxc","type":"discover_new","discover_by":"category_url","limit_per_input":50,"retryable_http_statuses":[408,425,429,500,502,503,504],"max_attempts":6}'::jsonb,
  '{"parser_version":"brightdata_harborfreight_v1","reject_missing_item_id":true,"reject_missing_title":true,"reject_missing_price":false,"missing_price_action":"preserve_product_withhold_offer_and_log_dq"}'::jsonb,
  '{"unlocker_mode":"fallback","zones":["tcds_web_unlocker"],"zone_policy":"standard_only","retain_html":false}'::jsonb
FROM retail.retail_platforms WHERE platform_code='harborfreight'
AND NOT EXISTS (
  SELECT 1 FROM retail.platform_collection_configs c
  WHERE c.platform_id=retail.retail_platforms.id AND c.config_name='Harbor Freight Bright Data tools and automotive ingest v1'
);

CREATE UNIQUE INDEX IF NOT EXISTS ux_raw_product_capture_idempotency
  ON retail.raw_product_captures(platform_id,platform_product_key,payload_hash);
CREATE UNIQUE INDEX IF NOT EXISTS ux_retail_products_platform_product
  ON retail.retail_products(platform_id,platform_product_key);
CREATE UNIQUE INDEX IF NOT EXISTS ux_offer_platform_hash
  ON retail.retail_offer_snapshots(platform_id,offer_hash);
CREATE UNIQUE INDEX IF NOT EXISTS ux_ingest_dead_letters_source_payload
  ON retail.ingest_dead_letters(source_platform,payload_hash);
CREATE INDEX IF NOT EXISTS ix_ingest_dlq_retry
  ON retail.ingest_dead_letters(status,next_retry_at)
  WHERE status IN ('pending','retrying');

CREATE TABLE IF NOT EXISTS retail.harborfreight_product_parsed (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  raw_capture_id uuid NOT NULL UNIQUE REFERENCES retail.raw_product_captures(id),
  collection_run_id uuid REFERENCES retail.collection_runs(id),
  platform_id uuid NOT NULL REFERENCES retail.retail_platforms(id),
  source_platform text NOT NULL DEFAULT 'harborfreight' CHECK(source_platform='harborfreight'),
  item_id text NOT NULL CHECK(length(btrim(item_id))>0),
  variant_id text,
  group_id text,
  gtin text,
  mpn text,
  url text NOT NULL CHECK(length(btrim(url))>0),
  title text NOT NULL CHECK(length(btrim(title))>0),
  normalized_title text GENERATED ALWAYS AS(lower(btrim(title))) STORED,
  description text,
  brand text,
  normalized_brand text GENERATED ALWAYS AS(lower(btrim(brand))) STORED,
  product_category text,
  category_tree jsonb NOT NULL DEFAULT '[]',
  image_url text,
  additional_image_urls jsonb NOT NULL DEFAULT '[]',
  additional_video_urls jsonb NOT NULL DEFAULT '[]',
  regular_price numeric(14,2),
  sale_price numeric(14,2),
  effective_price numeric(14,2) CHECK(effective_price IS NULL OR effective_price>=0),
  currency_code char(3) NOT NULL DEFAULT 'USD',
  availability text,
  availability_date text,
  listing_has_variations boolean NOT NULL DEFAULT false,
  variant_attributes jsonb NOT NULL DEFAULT '[]',
  variants jsonb NOT NULL DEFAULT '[]',
  store_name text,
  seller_url text,
  seller_privacy_policy text,
  seller_tos text,
  return_policy text,
  return_window integer CHECK(return_window IS NULL OR return_window>=0),
  review_count integer CHECK(review_count IS NULL OR review_count>=0),
  star_rating numeric(3,2) CHECK(star_rating IS NULL OR star_rating BETWEEN 0 AND 5),
  reviews jsonb NOT NULL DEFAULT '[]',
  target_countries jsonb NOT NULL DEFAULT '[]',
  store_country text,
  category_urls jsonb NOT NULL DEFAULT '[]',
  source_dataset text NOT NULL DEFAULT 'brightdata_harborfreight',
  parser_version text NOT NULL DEFAULT 'brightdata_harborfreight_v1',
  parsed_payload jsonb NOT NULL,
  payload_hash text NOT NULL,
  parsed_at timestamptz NOT NULL DEFAULT now(),
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  UNIQUE(platform_id,item_id,variant_id,payload_hash)
);

CREATE INDEX IF NOT EXISTS ix_harborfreight_item_latest ON retail.harborfreight_product_parsed(item_id,parsed_at DESC);
CREATE INDEX IF NOT EXISTS ix_harborfreight_variant_latest ON retail.harborfreight_product_parsed(variant_id,parsed_at DESC) WHERE variant_id IS NOT NULL;
CREATE INDEX IF NOT EXISTS ix_harborfreight_gtin ON retail.harborfreight_product_parsed(gtin) WHERE gtin IS NOT NULL;
CREATE INDEX IF NOT EXISTS ix_harborfreight_mpn ON retail.harborfreight_product_parsed(mpn) WHERE mpn IS NOT NULL;
CREATE INDEX IF NOT EXISTS ix_harborfreight_price_availability ON retail.harborfreight_product_parsed(effective_price,availability) WHERE effective_price IS NOT NULL;
CREATE INDEX IF NOT EXISTS ix_harborfreight_brand_title ON retail.harborfreight_product_parsed(normalized_brand,normalized_title);
CREATE INDEX IF NOT EXISTS ix_harborfreight_payload_gin ON retail.harborfreight_product_parsed USING gin(parsed_payload);

CREATE TABLE IF NOT EXISTS retail.harborfreight_product_images (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  harborfreight_parsed_id uuid NOT NULL REFERENCES retail.harborfreight_product_parsed(id) ON DELETE CASCADE,
  image_url text NOT NULL,
  image_rank integer NOT NULL CHECK(image_rank>=1),
  is_main boolean NOT NULL DEFAULT false,
  created_at timestamptz NOT NULL DEFAULT now(),
  UNIQUE(harborfreight_parsed_id,image_url)
);

CREATE TABLE IF NOT EXISTS retail.harborfreight_product_categories (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  harborfreight_parsed_id uuid NOT NULL REFERENCES retail.harborfreight_product_parsed(id) ON DELETE CASCADE,
  category_rank integer NOT NULL CHECK(category_rank>=1),
  category_name text NOT NULL,
  category_url text,
  created_at timestamptz NOT NULL DEFAULT now(),
  UNIQUE(harborfreight_parsed_id,category_rank)
);


CREATE TABLE IF NOT EXISTS retail.harborfreight_product_specifications (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  harborfreight_parsed_id uuid NOT NULL REFERENCES retail.harborfreight_product_parsed(id) ON DELETE CASCADE,
  specification_rank integer NOT NULL CHECK(specification_rank>=1),
  specification_name text NOT NULL CHECK(length(btrim(specification_name))>0),
  specification_value text,
  normalized_specification_name text GENERATED ALWAYS AS(lower(btrim(specification_name))) STORED,
  created_at timestamptz NOT NULL DEFAULT now(),
  UNIQUE(harborfreight_parsed_id,specification_rank)
);
CREATE INDEX IF NOT EXISTS ix_harborfreight_specs_name_value ON retail.harborfreight_product_specifications(normalized_specification_name,specification_value);

CREATE TABLE IF NOT EXISTS retail.harborfreight_unlocker_evidence (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  collection_run_id uuid REFERENCES retail.collection_runs(id),
  platform_id uuid NOT NULL REFERENCES retail.retail_platforms(id),
  target_url text NOT NULL,
  unlocker_zone text NOT NULL CHECK(unlocker_zone IN ('tcds_web_unlocker','tcds_premium_unlocker')),
  content_type text,
  response_status integer NOT NULL DEFAULT 200,
  content_hash text NOT NULL UNIQUE,
  response_body text NOT NULL,
  captured_at timestamptz NOT NULL DEFAULT now(),
  evidence_metadata jsonb NOT NULL DEFAULT '{}'
);
CREATE INDEX IF NOT EXISTS ix_harborfreight_unlocker_url_time ON retail.harborfreight_unlocker_evidence(target_url,captured_at DESC);

COMMIT;
