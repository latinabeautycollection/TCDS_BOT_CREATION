BEGIN;

INSERT INTO retail.retail_platforms(platform_code,platform_name,base_url,access_type,status,priority_rank,is_purchase_supported,is_data_collection_supported,max_daily_requests,max_hourly_requests,robots_policy_url,terms_url,governance_notes)
SELECT 'lowes','Lowe''s','https://www.lowes.com',access_type,status,40,true,true,5000,500,
  'https://www.lowes.com/robots.txt','https://www.lowes.com/l/about/terms-and-conditions-of-use',
  'Standard Web Unlocker JSON-mode category discovery feeds canonical PDP URLs to Bright Data Lowe''s dataset gd_lnvl79pfftqh18u2o.'
FROM retail.retail_platforms ORDER BY created_at LIMIT 1
ON CONFLICT(platform_code) DO UPDATE SET platform_name=EXCLUDED.platform_name,base_url=EXCLUDED.base_url,is_data_collection_supported=true,governance_notes=EXCLUDED.governance_notes,updated_at=now();

DO $$ BEGIN
 IF NOT EXISTS (SELECT 1 FROM retail.retail_platforms WHERE platform_code='lowes') THEN
   RAISE EXCEPTION 'Cannot seed Lowe''s: retail.retail_platforms has no row from which enum values can be copied';
 END IF;
END $$;

INSERT INTO retail.platform_collection_configs(platform_id,config_name,is_active,schedule_cron,collection_strategy,category_seed_json,search_seed_json,request_policy_json,parser_policy_json,evidence_policy_json)
SELECT id,'Lowe''s Bright Data category ingest v1',true,NULL,'web_unlocker_json_category_to_pdp',
 '[{"url":"https://www.lowes.com/pl/power-tools/4294607842?goToProdList=true","category":"power_tools","source_type":"category_page"},{"url":"https://www.lowes.com/pl/outdoor-tools-equipment/lawn-mowers/push-lawn-mowers/4294612707","category":"push_lawn_mowers","source_type":"category_page"}]'::jsonb,'[]'::jsonb,
 '{"dataset_id":"gd_lnvl79pfftqh18u2o","discovery_limit":50,"detail_limit_per_input":1,"location_aware":true,"unlocker_country":"us","retryable_http_statuses":[408,425,429,500,502,503,504],"max_attempts":6}'::jsonb,
 '{"parser_version":"brightdata_lowes_v1","reject_missing_marketplace_pn":true,"reject_missing_product_name":true,"reject_missing_price":false,"missing_price_action":"preserve_product_withhold_offer_and_log_dq","effective_price_rule":"lowest_valid_observed_price","discount_verification":"source_vs_computed","null_array_policy":"normalize_to_empty"}'::jsonb,
 '{"unlocker_mode":"category_discovery","zones":["tcds_web_unlocker"],"zone_policy":"standard_only","response_format":"json","retain_html":false}'::jsonb
FROM retail.retail_platforms WHERE platform_code='lowes'
AND NOT EXISTS (SELECT 1 FROM retail.platform_collection_configs c WHERE c.platform_id=retail.retail_platforms.id AND c.config_name='Lowe''s Bright Data category ingest v1');

CREATE UNIQUE INDEX IF NOT EXISTS ux_raw_product_capture_idempotency ON retail.raw_product_captures(platform_id,platform_product_key,payload_hash);
CREATE UNIQUE INDEX IF NOT EXISTS ux_retail_products_platform_product ON retail.retail_products(platform_id,platform_product_key);
CREATE UNIQUE INDEX IF NOT EXISTS ux_offer_platform_hash ON retail.retail_offer_snapshots(platform_id,offer_hash);
CREATE UNIQUE INDEX IF NOT EXISTS ux_ingest_dead_letters_source_payload ON retail.ingest_dead_letters(source_platform,payload_hash);
CREATE INDEX IF NOT EXISTS ix_ingest_dlq_retry ON retail.ingest_dead_letters(status,next_retry_at) WHERE status IN ('pending','retrying');

CREATE TABLE IF NOT EXISTS retail.lowes_product_parsed (
 id uuid PRIMARY KEY DEFAULT gen_random_uuid(), raw_capture_id uuid NOT NULL UNIQUE REFERENCES retail.raw_product_captures(id),
 collection_run_id uuid REFERENCES retail.collection_runs(id), platform_id uuid NOT NULL REFERENCES retail.retail_platforms(id),
 source_platform text NOT NULL DEFAULT 'lowes' CHECK(source_platform='lowes'), marketplace_pn text NOT NULL CHECK(length(btrim(marketplace_pn))>0),
 sku text, other_pn text, model_number text, gtin_ean_pn text, upc text, url text NOT NULL, product_name text NOT NULL,
 normalized_product_name text GENERATED ALWAYS AS(lower(btrim(product_name))) STORED, description text, brand text,
 normalized_brand text GENERATED ALWAYS AS(lower(btrim(brand))) STORED, product_category text, root_category text,
 category_tree jsonb NOT NULL DEFAULT '[]', nai_category_tree jsonb NOT NULL DEFAULT '[]', main_image text, image_urls jsonb NOT NULL DEFAULT '[]',
 initial_price numeric(14,2), final_price numeric(14,2), displayed_price numeric(14,2), sale_price numeric(14,2), effective_price numeric(14,2),
 discount_value numeric, computed_discount_percent numeric, currency char(3) NOT NULL DEFAULT 'USD', in_stock boolean,
 availability jsonb NOT NULL DEFAULT '[]', availability_status text, availability_date text, available_to_delivery integer,
 delivery_offers jsonb, delivery jsonb NOT NULL DEFAULT '[]', seller_name text, seller_id text, seller_url text,
 date_first_available timestamptz, badges jsonb NOT NULL DEFAULT '[]', rating numeric(5,4), reviews_count integer,
 reviews jsonb NOT NULL DEFAULT '[]', top_reviews jsonb NOT NULL DEFAULT '[]', dimensions jsonb, weight text, specifications jsonb NOT NULL DEFAULT '[]',
 listing_has_variations boolean NOT NULL DEFAULT false, variant_attributes jsonb NOT NULL DEFAULT '[]', variants jsonb NOT NULL DEFAULT '[]',
 store_name text, location text, in_store_location jsonb, seller_privacy_policy text, seller_tos text, return_policy text, return_window integer,
 target_countries jsonb NOT NULL DEFAULT '[]', store_country text, category_urls jsonb NOT NULL DEFAULT '[]',
 source_dataset text NOT NULL DEFAULT 'brightdata_lowes', parser_version text NOT NULL DEFAULT 'brightdata_lowes_v1',
 parsed_payload jsonb NOT NULL, payload_hash text NOT NULL, parsed_at timestamptz NOT NULL DEFAULT now(),created_at timestamptz NOT NULL DEFAULT now(),updated_at timestamptz NOT NULL DEFAULT now(),
 CHECK(effective_price IS NULL OR effective_price>=0), CHECK(rating IS NULL OR rating BETWEEN 0 AND 5), CHECK(reviews_count IS NULL OR reviews_count>=0),
 UNIQUE(platform_id,marketplace_pn,sku,payload_hash)
);
CREATE INDEX IF NOT EXISTS ix_lowes_item_latest ON retail.lowes_product_parsed(marketplace_pn,parsed_at DESC);
CREATE INDEX IF NOT EXISTS ix_lowes_sku_latest ON retail.lowes_product_parsed(sku,parsed_at DESC) WHERE sku IS NOT NULL;
CREATE INDEX IF NOT EXISTS ix_lowes_upc ON retail.lowes_product_parsed(upc) WHERE upc IS NOT NULL;
CREATE INDEX IF NOT EXISTS ix_lowes_model ON retail.lowes_product_parsed(model_number) WHERE model_number IS NOT NULL;
CREATE INDEX IF NOT EXISTS ix_lowes_price_availability ON retail.lowes_product_parsed(effective_price,availability_status) WHERE effective_price IS NOT NULL;
CREATE INDEX IF NOT EXISTS ix_lowes_payload_gin ON retail.lowes_product_parsed USING gin(parsed_payload);

CREATE TABLE IF NOT EXISTS retail.lowes_product_images(id uuid PRIMARY KEY DEFAULT gen_random_uuid(),lowes_parsed_id uuid NOT NULL REFERENCES retail.lowes_product_parsed(id) ON DELETE CASCADE,image_url text NOT NULL,image_rank integer NOT NULL CHECK(image_rank>=1),is_main boolean NOT NULL DEFAULT false,created_at timestamptz NOT NULL DEFAULT now(),UNIQUE(lowes_parsed_id,image_url));
CREATE TABLE IF NOT EXISTS retail.lowes_product_categories(id uuid PRIMARY KEY DEFAULT gen_random_uuid(),lowes_parsed_id uuid NOT NULL REFERENCES retail.lowes_product_parsed(id) ON DELETE CASCADE,category_rank integer NOT NULL CHECK(category_rank>=1),category_name text NOT NULL,category_url text,created_at timestamptz NOT NULL DEFAULT now(),UNIQUE(lowes_parsed_id,category_rank));
CREATE TABLE IF NOT EXISTS retail.lowes_unlocker_evidence(id uuid PRIMARY KEY DEFAULT gen_random_uuid(),collection_run_id uuid REFERENCES retail.collection_runs(id),platform_id uuid NOT NULL REFERENCES retail.retail_platforms(id),target_url text NOT NULL,unlocker_zone text NOT NULL CHECK(unlocker_zone IN ('tcds_web_unlocker','tcds_premium_unlocker')),content_type text,response_status integer NOT NULL DEFAULT 200,content_hash text NOT NULL UNIQUE,response_body text NOT NULL,captured_at timestamptz NOT NULL DEFAULT now(),evidence_metadata jsonb NOT NULL DEFAULT '{}');
CREATE INDEX IF NOT EXISTS ix_lowes_unlocker_url_time ON retail.lowes_unlocker_evidence(target_url,captured_at DESC);
COMMIT;
