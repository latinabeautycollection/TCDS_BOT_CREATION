do $$
begin
  create type retail.microcenter_offer_status as enum ('available', 'out_of_stock', 'limited', 'unknown');
exception when duplicate_object then null;
end $$;

do $$
begin
  create type retail.microcenter_promotion_status as enum ('not_promoted', 'promoted', 'failed', 'skipped');
exception when duplicate_object then null;
end $$;

insert into retail.retail_platforms (
  platform_code, platform_name, base_url, access_type, status,
  priority_rank, is_purchase_supported, is_data_collection_supported
)
values (
  'microcenter', 'Micro Center', 'https://www.microcenter.com',
  'authorized_scraper', 'active', 4, true, true
)
on conflict (platform_code) do update set
  platform_name = excluded.platform_name,
  base_url = excluded.base_url,
  is_data_collection_supported = true,
  updated_at = now();

create table if not exists retail.microcenter_product_parsed (
  id uuid primary key default gen_random_uuid(),
  raw_capture_id uuid not null references retail.raw_product_captures(id),
  collection_run_id uuid,
  platform_id uuid not null references retail.retail_platforms(id),

  item_id text not null,
  sku text,
  url text not null,
  title text not null,
  description text,
  brand text,
  mpn text,
  upc text,
  gtin text,

  product_category text,
  category_tree jsonb not null default '[]'::jsonb,

  final_price numeric,
  sale_price numeric,
  effective_price numeric,
  currency_code char(3) not null default 'USD',
  price_text text,

  availability text,
  availability_date timestamptz,
  offer_status retail.microcenter_offer_status not null default 'unknown',

  rating numeric,
  review_count integer,

  image_url text,
  additional_image_urls jsonb not null default '[]'::jsonb,
  additional_video_urls jsonb not null default '[]'::jsonb,

  product_attributes jsonb not null default '[]'::jsonb,
  features jsonb not null default '[]'::jsonb,
  reviews jsonb not null default '[]'::jsonb,

  store_name text,
  store_country text,
  seller_url text,
  seller_privacy_policy text,
  seller_tos text,
  return_policy text,
  return_window integer,
  target_countries jsonb not null default '[]'::jsonb,

  listing_has_variations boolean,
  variant_attributes jsonb not null default '[]'::jsonb,
  variants jsonb not null default '[]'::jsonb,

  source_dataset text not null default 'brightdata_microcenter',
  parser_version text not null default 'brightdata_microcenter_v1',
  promotion_status retail.microcenter_promotion_status not null default 'not_promoted',
  promoted_retail_product_id uuid,
  promoted_offer_snapshot_id uuid,
  promoted_at timestamptz,
  promotion_error text,

  parsed_payload jsonb not null,
  payload_hash text not null,
  parsed_at timestamptz not null default now(),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),

  unique(platform_id, item_id, raw_capture_id)
);

create or replace function retail.ingest_brightdata_microcenter_product(
  p_raw_capture_id uuid,
  p_payload jsonb
)
returns uuid
language plpgsql
as $$
declare
  v_platform_id uuid;
  v_raw_platform_id uuid;
  v_collection_run_id uuid;
  v_parsed_id uuid;
  v_payload_hash text;
  v_item_id text;
  v_url text;
  v_title text;
  v_sku text;
  v_upc text;
begin
  select id into v_platform_id
  from retail.retail_platforms
  where platform_code = 'microcenter';

  select platform_id, collection_run_id
  into v_raw_platform_id, v_collection_run_id
  from retail.raw_product_captures
  where id = p_raw_capture_id;

  if v_raw_platform_id is null then
    raise exception 'Raw capture not found: %', p_raw_capture_id;
  end if;

  if v_raw_platform_id <> v_platform_id then
    raise exception 'Raw capture % is not a Micro Center capture', p_raw_capture_id;
  end if;

  v_url := nullif(trim(coalesce(p_payload->>'url', p_payload#>>'{input,url}')), '');
  v_item_id := nullif(trim(coalesce(
    p_payload->>'item_id',
    substring(coalesce(v_url, '') from '/product/([0-9]+)')
  )), '');
  v_title := nullif(trim(coalesce(p_payload->>'title', p_payload->>'name')), '');

  select elem->>'value' into v_sku
  from jsonb_array_elements(coalesce(p_payload->'product_attributes', '[]'::jsonb)) elem
  where lower(elem->>'name') = 'sku'
  limit 1;

  select elem->>'value' into v_upc
  from jsonb_array_elements(coalesce(p_payload->'product_attributes', '[]'::jsonb)) elem
  where lower(elem->>'name') in ('upc', 'gtin')
  limit 1;

  if v_item_id is null then
    raise exception 'Missing Micro Center item_id/url';
  end if;

  if v_url is null then
    v_url := 'https://www.microcenter.com/product/' || v_item_id || '/-';
  end if;

  if v_title is null then
    raise exception 'Missing Micro Center title';
  end if;

  v_payload_hash := encode(digest(p_payload::text, 'sha256'), 'hex');

  insert into retail.microcenter_product_parsed (
    raw_capture_id, collection_run_id, platform_id,
    item_id, sku, url, title, description, brand, mpn, upc, gtin,
    product_category, category_tree,
    final_price, sale_price, effective_price, currency_code, price_text,
    availability, availability_date, offer_status,
    rating, review_count,
    image_url, additional_image_urls, additional_video_urls,
    product_attributes, features, reviews,
    store_name, store_country, seller_url, seller_privacy_policy, seller_tos,
    return_policy, return_window, target_countries,
    listing_has_variations, variant_attributes, variants,
    parsed_payload, payload_hash
  )
  values (
    p_raw_capture_id, v_collection_run_id, v_platform_id,
    v_item_id, v_sku, v_url, v_title, p_payload->>'description', p_payload->>'brand',
    p_payload->>'mpn', coalesce(p_payload->>'upc', v_upc), coalesce(p_payload->>'gtin', v_upc),
    p_payload->>'product_category', coalesce(p_payload->'category_tree', '[]'::jsonb),
    retail.safe_numeric(coalesce(p_payload->>'price', p_payload->>'final_price')),
    retail.safe_numeric(p_payload->>'sale_price'),
    coalesce(retail.safe_numeric(p_payload->>'sale_price'), retail.safe_numeric(coalesce(p_payload->>'price', p_payload->>'final_price'))),
    coalesce(nullif(p_payload->>'currency',''), 'USD')::char(3),
    coalesce(p_payload->>'sale_price', p_payload->>'price'),
    p_payload->>'availability',
    case when coalesce(p_payload->>'availability_date','') ~ '^[0-9]{4}-[0-9]{2}-[0-9]{2}$'
      then (p_payload->>'availability_date')::date::timestamptz
      else null
    end,
    case
      when lower(coalesce(p_payload->>'availability','')) like '%out%' then 'out_of_stock'::retail.microcenter_offer_status
      when lower(coalesce(p_payload->>'availability','')) like '%limited%' then 'limited'::retail.microcenter_offer_status
      when lower(coalesce(p_payload->>'availability','')) like '%stock%' then 'available'::retail.microcenter_offer_status
      else 'unknown'::retail.microcenter_offer_status
    end,
    case when retail.safe_numeric(p_payload->>'star_rating') between 0 and 5 then retail.safe_numeric(p_payload->>'star_rating') else null end,
    retail.safe_integer(p_payload->>'review_count'),
    p_payload->>'image_url',
    coalesce(p_payload->'additional_image_urls', '[]'::jsonb),
    coalesce(p_payload->'additional_video_urls', '[]'::jsonb),
    coalesce(p_payload->'product_attributes', '[]'::jsonb),
    coalesce(p_payload->'features', '[]'::jsonb),
    coalesce(p_payload->'reviews', '[]'::jsonb),
    p_payload->>'store_name',
    p_payload->>'store_country',
    p_payload->>'seller_url',
    p_payload->>'seller_privacy_policy',
    p_payload->>'seller_tos',
    p_payload->>'return_policy',
    retail.safe_integer(p_payload->>'return_window'),
    coalesce(p_payload->'target_countries', '[]'::jsonb),
    retail.safe_boolean(p_payload->>'listing_has_variations'),
    coalesce(p_payload->'variant_attributes', '[]'::jsonb),
    coalesce(p_payload->'variants', '[]'::jsonb),
    p_payload,
    v_payload_hash
  )
  on conflict (platform_id, item_id, raw_capture_id)
  do update set
    sku = excluded.sku,
    url = excluded.url,
    title = excluded.title,
    description = excluded.description,
    brand = excluded.brand,
    mpn = excluded.mpn,
    upc = excluded.upc,
    gtin = excluded.gtin,
    final_price = excluded.final_price,
    sale_price = excluded.sale_price,
    effective_price = excluded.effective_price,
    availability = excluded.availability,
    offer_status = excluded.offer_status,
    rating = excluded.rating,
    review_count = excluded.review_count,
    image_url = excluded.image_url,
    parsed_payload = excluded.parsed_payload,
    payload_hash = excluded.payload_hash,
    updated_at = now()
  returning id into v_parsed_id;

  return v_parsed_id;
end;
$$;

create or replace function retail.promote_microcenter_parsed_product(
  p_microcenter_parsed_id uuid
)
returns uuid
language plpgsql
as $$
declare
  v_parsed retail.microcenter_product_parsed%rowtype;
  v_retail_product_id uuid;
  v_offer_snapshot_id uuid;
  v_availability retail.product_availability;
begin
  select * into v_parsed
  from retail.microcenter_product_parsed
  where id = p_microcenter_parsed_id;

  if v_parsed.id is null then
    raise exception 'Micro Center parsed product not found: %', p_microcenter_parsed_id;
  end if;

  v_availability :=
    case v_parsed.offer_status
      when 'available' then 'in_stock'::retail.product_availability
      when 'limited' then 'limited_stock'::retail.product_availability
      when 'out_of_stock' then 'out_of_stock'::retail.product_availability
      else 'unknown'::retail.product_availability
    end;

  insert into retail.retail_products (
    platform_id, platform_product_key, source_url, title, brand,
    model_number, upc, sku, category_path, image_url,
    first_seen_at, last_seen_at, is_active, normalized_json
  )
  values (
    v_parsed.platform_id, v_parsed.item_id, v_parsed.url, v_parsed.title, v_parsed.brand,
    v_parsed.mpn, coalesce(v_parsed.upc, v_parsed.gtin), coalesce(v_parsed.sku, v_parsed.item_id),
    v_parsed.product_category, v_parsed.image_url,
    now(), now(), true, v_parsed.parsed_payload
  )
  on conflict (platform_id, platform_product_key)
  do update set
    source_url = excluded.source_url,
    title = excluded.title,
    brand = excluded.brand,
    model_number = excluded.model_number,
    upc = excluded.upc,
    sku = excluded.sku,
    category_path = excluded.category_path,
    image_url = excluded.image_url,
    last_seen_at = now(),
    is_active = true,
    normalized_json = excluded.normalized_json,
    updated_at = now()
  returning id into v_retail_product_id;

  v_offer_snapshot_id := retail.record_offer_snapshot(
    v_retail_product_id,
    v_parsed.effective_price,
    v_availability,
    null, null, null,
    v_parsed.url,
    v_parsed.raw_capture_id,
    jsonb_build_object(
      'source', 'brightdata',
      'retailer', 'microcenter',
      'currency', coalesce(v_parsed.currency_code::text, 'USD'),
      'parsed_id', v_parsed.id,
      'rating', v_parsed.rating,
      'review_count', v_parsed.review_count,
      'sale_price', v_parsed.sale_price,
      'list_price', v_parsed.final_price,
      'mpn', v_parsed.mpn,
      'gtin', v_parsed.gtin,
      'store_name', v_parsed.store_name,
      'product_attributes', v_parsed.product_attributes
    )
  );

  perform retail.enqueue_erip_source_export(v_offer_snapshot_id);

  update retail.microcenter_product_parsed
  set promotion_status = 'promoted'::retail.microcenter_promotion_status,
      promoted_retail_product_id = v_retail_product_id,
      promoted_offer_snapshot_id = v_offer_snapshot_id,
      promoted_at = now(),
      promotion_error = null,
      updated_at = now()
  where id = v_parsed.id;

  return v_retail_product_id;
exception
  when others then
    update retail.microcenter_product_parsed
    set promotion_status = 'failed'::retail.microcenter_promotion_status,
        promotion_error = sqlerrm,
        updated_at = now()
    where id = p_microcenter_parsed_id;

    raise;
end;
$$;
