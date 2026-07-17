BEGIN;

INSERT INTO retail.retail_platforms (
  platform_code,
  platform_name,
  base_url,
  access_type,
  status,
  priority_rank,
  is_purchase_supported,
  is_data_collection_supported,
  robots_policy_url,
  terms_url,
  governance_notes
)
VALUES (
  'bhphotovideo',
  'B&H Photo Video',
  'https://www.bhphotovideo.com',
  'authorized_scraper',
  'active',
  35,
  true,
  true,
  'https://www.bhphotovideo.com/robots.txt',
  'https://www.bhphotovideo.com/find/HelpCenter/Policies.jsp',
  'Bright Data B&H PDP dataset with category discovery through tcds_web_unlocker.'
)
ON CONFLICT (platform_code) DO UPDATE SET
  platform_name = EXCLUDED.platform_name,
  base_url = EXCLUDED.base_url,
  is_data_collection_supported = true,
  governance_notes = EXCLUDED.governance_notes,
  updated_at = now();

INSERT INTO retail.platform_collection_configs (
  platform_id,
  config_name,
  is_active,
  collection_strategy,
  category_seed_json,
  search_seed_json,
  request_policy_json,
  parser_policy_json,
  evidence_policy_json
)
SELECT
  p.id,
  'brightdata_bhphoto_category_v1',
  true,
  'web_unlocker_category_to_pdp',
  jsonb_build_array(
    'https://www.bhphotovideo.com/c/buy/clip-on-wireless-microphone-systems/ci/63635',
    'https://www.bhphotovideo.com/c/products/laptops/ci/18818?filters=fct_price%3A0..500',
    'https://www.bhphotovideo.com/c/browse/DJ-Equipment/ci/13932',
    'https://www.bhphotovideo.com/c/browse/drone-with-camera/ci/27989/N/3765401970'
  ),
  '[]'::jsonb,
  jsonb_build_object(
    'dataset_id', 'gd_mkce0sox1mchrlpp8g',
    'web_unlocker_zone', 'tcds_web_unlocker',
    'limit', 50,
    'detail_limit_per_input', 1
  ),
  jsonb_build_object('parser_version', 'brightdata_bhphoto_v1'),
  jsonb_build_object('store_raw', true, 'source_platform', 'bhphotovideo')
FROM retail.retail_platforms p
WHERE p.platform_code = 'bhphotovideo'
ON CONFLICT (platform_id, config_name) DO UPDATE SET
  is_active = EXCLUDED.is_active,
  collection_strategy = EXCLUDED.collection_strategy,
  category_seed_json = EXCLUDED.category_seed_json,
  request_policy_json = EXCLUDED.request_policy_json,
  parser_policy_json = EXCLUDED.parser_policy_json,
  evidence_policy_json = EXCLUDED.evidence_policy_json,
  updated_at = now();

CREATE TABLE IF NOT EXISTS retail.bhphoto_product_parsed (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  raw_capture_id uuid NOT NULL UNIQUE
    REFERENCES retail.raw_product_captures(id) ON DELETE CASCADE,
  collection_run_id uuid REFERENCES retail.collection_runs(id),
  platform_id uuid NOT NULL REFERENCES retail.retail_platforms(id),
  source_platform text NOT NULL DEFAULT 'bhphotovideo'
    CHECK (source_platform = 'bhphotovideo'),

  item_id text NOT NULL,
  url text NOT NULL,
  title text NOT NULL,
  description text,
  brand text,
  mpn text,
  gtin text,
  upc text,

  product_category text,
  category_tree jsonb NOT NULL DEFAULT '[]'::jsonb,
  category_urls jsonb NOT NULL DEFAULT '[]'::jsonb,

  regular_price numeric(14,2),
  sale_price numeric(14,2),
  effective_price numeric(14,2),
  currency_code char(3) NOT NULL DEFAULT 'USD',
  price_text text,

  availability text,
  availability_date text,
  star_rating numeric(3,2)
    CHECK (star_rating IS NULL OR star_rating BETWEEN 0 AND 5),
  review_count integer
    CHECK (review_count IS NULL OR review_count >= 0),

  image_url text,
  additional_image_urls jsonb NOT NULL DEFAULT '[]'::jsonb,
  additional_video_urls jsonb NOT NULL DEFAULT '[]'::jsonb,
  listing_has_variations boolean NOT NULL DEFAULT false,
  variant_attributes jsonb NOT NULL DEFAULT '[]'::jsonb,
  variants jsonb NOT NULL DEFAULT '[]'::jsonb,

  reviews jsonb NOT NULL DEFAULT '[]'::jsonb,
  features jsonb NOT NULL DEFAULT '[]'::jsonb,
  related_products jsonb NOT NULL DEFAULT '[]'::jsonb,
  product_attributes jsonb NOT NULL DEFAULT '[]'::jsonb,

  store_name text,
  seller_url text,
  seller_privacy_policy text,
  seller_tos text,
  return_policy text,
  return_window integer,
  target_countries jsonb NOT NULL DEFAULT '[]'::jsonb,
  store_country text,

  source_dataset text NOT NULL DEFAULT 'gd_mkce0sox1mchrlpp8g',
  parser_version text NOT NULL DEFAULT 'brightdata_bhphoto_v1',
  promotion_status text NOT NULL DEFAULT 'not_promoted'
    CHECK (promotion_status IN ('not_promoted', 'promoted', 'failed', 'skipped')),
  promoted_retail_product_id uuid REFERENCES retail.retail_products(id),
  promoted_offer_snapshot_id uuid REFERENCES retail.retail_offer_snapshots(id),
  promoted_at timestamptz,
  promotion_error text,

  parsed_payload jsonb NOT NULL,
  payload_hash text NOT NULL,
  parsed_at timestamptz NOT NULL DEFAULT now(),
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),

  UNIQUE (platform_id, item_id, payload_hash)
);

CREATE INDEX IF NOT EXISTS ix_bhphoto_item_latest
  ON retail.bhphoto_product_parsed(item_id, parsed_at DESC);
CREATE INDEX IF NOT EXISTS ix_bhphoto_mpn
  ON retail.bhphoto_product_parsed(mpn) WHERE mpn IS NOT NULL;
CREATE INDEX IF NOT EXISTS ix_bhphoto_gtin
  ON retail.bhphoto_product_parsed(gtin) WHERE gtin IS NOT NULL;
CREATE INDEX IF NOT EXISTS ix_bhphoto_price_availability
  ON retail.bhphoto_product_parsed(effective_price, availability);
CREATE INDEX IF NOT EXISTS ix_bhphoto_payload_gin
  ON retail.bhphoto_product_parsed USING gin(parsed_payload);

CREATE OR REPLACE FUNCTION retail.ingest_brightdata_bhphoto_product(
  p_raw_capture_id uuid,
  p_payload jsonb
)
RETURNS uuid
LANGUAGE plpgsql
AS $$
DECLARE
  v_platform_id uuid;
  v_raw_platform_id uuid;
  v_collection_run_id uuid;
  v_parsed_id uuid;
  v_payload_hash text;
  v_item_id text;
  v_url text;
  v_title text;
  v_regular_price numeric;
  v_sale_price numeric;
BEGIN
  SELECT id INTO v_platform_id
  FROM retail.retail_platforms
  WHERE platform_code = 'bhphotovideo';

  IF v_platform_id IS NULL THEN
    RAISE EXCEPTION 'B&H platform is not registered';
  END IF;

  SELECT platform_id, collection_run_id
  INTO v_raw_platform_id, v_collection_run_id
  FROM retail.raw_product_captures
  WHERE id = p_raw_capture_id;

  IF v_raw_platform_id IS NULL THEN
    RAISE EXCEPTION 'Raw capture not found: %', p_raw_capture_id;
  END IF;

  IF v_raw_platform_id <> v_platform_id THEN
    RAISE EXCEPTION 'Raw capture % is not a B&H capture', p_raw_capture_id;
  END IF;

  v_url := nullif(trim(coalesce(p_payload->>'url', p_payload#>>'{input,url}')), '');
  v_item_id := nullif(trim(coalesce(
    p_payload->>'item_id',
    substring(coalesce(v_url, '') from '/c/product/([0-9]+)')
  )), '');
  v_title := nullif(trim(coalesce(p_payload->>'title', p_payload->>'name')), '');
  v_regular_price := retail.safe_numeric(coalesce(p_payload->>'price', p_payload->>'final_price'));
  v_sale_price := retail.safe_numeric(p_payload->>'sale_price');

  IF v_item_id IS NULL THEN
    RAISE EXCEPTION 'Missing B&H item_id/url';
  END IF;
  IF v_url IS NULL THEN
    RAISE EXCEPTION 'Missing B&H product URL for item %', v_item_id;
  END IF;
  IF v_title IS NULL THEN
    RAISE EXCEPTION 'Missing B&H title for item %', v_item_id;
  END IF;

  v_payload_hash := encode(digest(p_payload::text, 'sha256'), 'hex');

  INSERT INTO retail.bhphoto_product_parsed (
    raw_capture_id, collection_run_id, platform_id,
    item_id, url, title, description, brand, mpn, gtin, upc,
    product_category, category_tree, category_urls,
    regular_price, sale_price, effective_price, currency_code, price_text,
    availability, availability_date, star_rating, review_count,
    image_url, additional_image_urls, additional_video_urls,
    listing_has_variations, variant_attributes, variants,
    reviews, features, related_products, product_attributes,
    store_name, seller_url, seller_privacy_policy, seller_tos,
    return_policy, return_window, target_countries, store_country,
    parsed_payload, payload_hash
  )
  VALUES (
    p_raw_capture_id, v_collection_run_id, v_platform_id,
    v_item_id, v_url, v_title, p_payload->>'description', p_payload->>'brand',
    p_payload->>'mpn', p_payload->>'gtin',
    coalesce(p_payload->>'upc', p_payload->>'gtin'),
    p_payload->>'product_category',
    CASE WHEN jsonb_typeof(p_payload->'category_tree') = 'array'
      THEN p_payload->'category_tree' ELSE '[]'::jsonb END,
    CASE WHEN jsonb_typeof(p_payload->'category_urls') = 'array'
      THEN p_payload->'category_urls' ELSE '[]'::jsonb END,
    v_regular_price, v_sale_price, coalesce(v_sale_price, v_regular_price),
    coalesce(nullif(upper(p_payload->>'currency'), ''), 'USD')::char(3),
    coalesce(p_payload->>'sale_price', p_payload->>'price'),
    p_payload->>'availability', p_payload->>'availability_date',
    CASE WHEN retail.safe_numeric(p_payload->>'star_rating') BETWEEN 0 AND 5
      THEN retail.safe_numeric(p_payload->>'star_rating') ELSE NULL END,
    retail.safe_integer(p_payload->>'review_count'),
    p_payload->>'image_url',
    CASE WHEN jsonb_typeof(p_payload->'additional_image_urls') = 'array'
      THEN p_payload->'additional_image_urls' ELSE '[]'::jsonb END,
    CASE WHEN jsonb_typeof(p_payload->'additional_video_urls') = 'array'
      THEN p_payload->'additional_video_urls' ELSE '[]'::jsonb END,
    coalesce(retail.safe_boolean(p_payload->>'listing_has_variations'), false),
    CASE WHEN jsonb_typeof(p_payload->'variant_attributes') = 'array'
      THEN p_payload->'variant_attributes' ELSE '[]'::jsonb END,
    CASE WHEN jsonb_typeof(p_payload->'variants') = 'array'
      THEN p_payload->'variants' ELSE '[]'::jsonb END,
    CASE WHEN jsonb_typeof(p_payload->'reviews') = 'array'
      THEN p_payload->'reviews' ELSE '[]'::jsonb END,
    CASE WHEN jsonb_typeof(p_payload->'features') = 'array'
      THEN p_payload->'features' ELSE '[]'::jsonb END,
    CASE WHEN jsonb_typeof(p_payload->'related_products') = 'array'
      THEN p_payload->'related_products' ELSE '[]'::jsonb END,
    CASE WHEN jsonb_typeof(p_payload->'product_attributes') = 'array'
      THEN p_payload->'product_attributes' ELSE '[]'::jsonb END,
    p_payload->>'store_name', p_payload->>'seller_url',
    p_payload->>'seller_privacy_policy', p_payload->>'seller_tos',
    p_payload->>'return_policy', retail.safe_integer(p_payload->>'return_window'),
    CASE WHEN jsonb_typeof(p_payload->'target_countries') = 'array'
      THEN p_payload->'target_countries' ELSE '[]'::jsonb END,
    p_payload->>'store_country', p_payload, v_payload_hash
  )
  ON CONFLICT (raw_capture_id) DO UPDATE SET
    item_id = EXCLUDED.item_id,
    url = EXCLUDED.url,
    title = EXCLUDED.title,
    description = EXCLUDED.description,
    brand = EXCLUDED.brand,
    mpn = EXCLUDED.mpn,
    gtin = EXCLUDED.gtin,
    upc = EXCLUDED.upc,
    product_category = EXCLUDED.product_category,
    category_tree = EXCLUDED.category_tree,
    category_urls = EXCLUDED.category_urls,
    regular_price = EXCLUDED.regular_price,
    sale_price = EXCLUDED.sale_price,
    effective_price = EXCLUDED.effective_price,
    availability = EXCLUDED.availability,
    availability_date = EXCLUDED.availability_date,
    star_rating = EXCLUDED.star_rating,
    review_count = EXCLUDED.review_count,
    image_url = EXCLUDED.image_url,
    additional_image_urls = EXCLUDED.additional_image_urls,
    additional_video_urls = EXCLUDED.additional_video_urls,
    listing_has_variations = EXCLUDED.listing_has_variations,
    variant_attributes = EXCLUDED.variant_attributes,
    variants = EXCLUDED.variants,
    reviews = EXCLUDED.reviews,
    features = EXCLUDED.features,
    related_products = EXCLUDED.related_products,
    product_attributes = EXCLUDED.product_attributes,
    parsed_payload = EXCLUDED.parsed_payload,
    payload_hash = EXCLUDED.payload_hash,
    updated_at = now()
  RETURNING id INTO v_parsed_id;

  RETURN v_parsed_id;
END;
$$;

CREATE OR REPLACE FUNCTION retail.promote_bhphoto_parsed_product(
  p_bhphoto_parsed_id uuid
)
RETURNS uuid
LANGUAGE plpgsql
AS $$
DECLARE
  v_parsed retail.bhphoto_product_parsed%rowtype;
  v_retail_product_id uuid;
  v_offer_snapshot_id uuid;
  v_availability retail.product_availability;
BEGIN
  SELECT * INTO v_parsed
  FROM retail.bhphoto_product_parsed
  WHERE id = p_bhphoto_parsed_id;

  IF v_parsed.id IS NULL THEN
    RAISE EXCEPTION 'B&H parsed product not found: %', p_bhphoto_parsed_id;
  END IF;

  IF v_parsed.effective_price IS NULL THEN
    RAISE EXCEPTION 'B&H product % has no effective price', v_parsed.item_id;
  END IF;

  v_availability := CASE
    WHEN lower(coalesce(v_parsed.availability, '')) IN ('in_stock', 'available')
      THEN 'in_stock'::retail.product_availability
    WHEN lower(coalesce(v_parsed.availability, '')) LIKE '%limited%'
      THEN 'limited_stock'::retail.product_availability
    WHEN lower(coalesce(v_parsed.availability, '')) LIKE '%preorder%'
      THEN 'preorder'::retail.product_availability
    WHEN lower(coalesce(v_parsed.availability, '')) LIKE '%out%'
      THEN 'out_of_stock'::retail.product_availability
    ELSE 'unknown'::retail.product_availability
  END;

  INSERT INTO retail.retail_products (
    platform_id, platform_product_key, source_url, title, brand,
    model_number, upc, sku, category_path, image_url,
    first_seen_at, last_seen_at, is_active, normalized_json
  )
  VALUES (
    v_parsed.platform_id, v_parsed.item_id, v_parsed.url, v_parsed.title,
    v_parsed.brand, v_parsed.mpn, coalesce(v_parsed.upc, v_parsed.gtin),
    v_parsed.item_id, v_parsed.product_category, v_parsed.image_url,
    now(), now(), v_availability <> 'out_of_stock', v_parsed.parsed_payload
  )
  ON CONFLICT (platform_id, platform_product_key) DO UPDATE SET
    source_url = EXCLUDED.source_url,
    title = EXCLUDED.title,
    brand = EXCLUDED.brand,
    model_number = EXCLUDED.model_number,
    upc = EXCLUDED.upc,
    sku = EXCLUDED.sku,
    category_path = EXCLUDED.category_path,
    image_url = EXCLUDED.image_url,
    last_seen_at = now(),
    is_active = EXCLUDED.is_active,
    normalized_json = EXCLUDED.normalized_json,
    updated_at = now()
  RETURNING id INTO v_retail_product_id;

  v_offer_snapshot_id := retail.record_offer_snapshot(
    v_retail_product_id,
    v_parsed.effective_price,
    v_availability,
    NULL,
    NULL,
    NULL,
    v_parsed.url,
    v_parsed.raw_capture_id,
    jsonb_build_object(
      'source', 'brightdata',
      'retailer', 'bhphotovideo',
      'currency', coalesce(v_parsed.currency_code::text, 'USD'),
      'parsed_id', v_parsed.id,
      'item_id', v_parsed.item_id,
      'rating', v_parsed.star_rating,
      'review_count', v_parsed.review_count,
      'regular_price', v_parsed.regular_price,
      'sale_price', v_parsed.sale_price,
      'mpn', v_parsed.mpn,
      'gtin', v_parsed.gtin,
      'listing_has_variations', v_parsed.listing_has_variations,
      'variant_attributes', v_parsed.variant_attributes,
      'variants', v_parsed.variants
    )
  );

  PERFORM retail.enqueue_erip_source_export(v_offer_snapshot_id);

  UPDATE retail.bhphoto_product_parsed
  SET promotion_status = 'promoted',
      promoted_retail_product_id = v_retail_product_id,
      promoted_offer_snapshot_id = v_offer_snapshot_id,
      promoted_at = now(),
      promotion_error = NULL,
      updated_at = now()
  WHERE id = v_parsed.id;

  RETURN v_retail_product_id;
EXCEPTION
  WHEN OTHERS THEN
    UPDATE retail.bhphoto_product_parsed
    SET promotion_status = 'failed',
        promotion_error = sqlerrm,
        updated_at = now()
    WHERE id = p_bhphoto_parsed_id;
    RAISE;
END;
$$;

COMMIT;
