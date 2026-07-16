create or replace function retail.ingest_brightdata_bestbuy_product(
  p_raw_capture_id uuid,
  p_payload jsonb
)
returns uuid
language plpgsql
as $function$
declare
  v_platform_id uuid;
  v_raw_platform_id uuid;
  v_collection_run_id uuid;
  v_parsed_id uuid;
  v_payload_hash text;
  v_product_id text;
  v_title text;
  v_url text;
  v_image jsonb;
  v_spec jsonb;
  v_idx integer;
begin
  if p_raw_capture_id is null then
    raise exception 'raw_capture_id is required';
  end if;

  if p_payload is null then
    raise exception 'payload is required';
  end if;

  select id
  into v_platform_id
  from retail.retail_platforms
  where platform_code = 'best_buy';

  if v_platform_id is null then
    raise exception 'Best Buy platform not found in retail.retail_platforms';
  end if;

  select platform_id, collection_run_id
  into v_raw_platform_id, v_collection_run_id
  from retail.raw_product_captures
  where id = p_raw_capture_id;

  if v_raw_platform_id is null then
    raise exception 'Raw capture not found: %', p_raw_capture_id;
  end if;

  if v_raw_platform_id <> v_platform_id then
    raise exception 'Raw capture % is not a Best Buy capture', p_raw_capture_id;
  end if;

  v_url := nullif(trim(coalesce(
    p_payload->>'url',
    p_payload->>'product_url',
    p_payload#>>'{input,url}'
  )), '');

  v_product_id := nullif(trim(coalesce(
    p_payload->>'product_id',
    p_payload->>'sku',
    p_payload->>'skuId',
    p_payload->>'sku_id',
    p_payload->>'id',
    substring(coalesce(v_url, '') from 'skuId=([0-9]+)')
  )), '');

  v_title := nullif(trim(coalesce(
    p_payload->>'title',
    p_payload->>'product_name',
    p_payload->>'name',
    p_payload->>'short_description',
    p_payload#>>'{input,name}'
  )), '');

  if v_product_id is null then
    raise exception 'Missing Best Buy product_id/sku/skuId/url';
  end if;

  if v_url is null then
    v_url := 'https://www.bestbuy.com/site/.p?skuId=' || v_product_id;
  end if;

  v_payload_hash := encode(digest(p_payload::text, 'sha256'), 'hex');

  insert into retail.bestbuy_product_parsed (
    raw_capture_id,
    collection_run_id,
    platform_id,
    product_id,
    sku,
    url,
    title,
    normalized_title,
    brand,
    normalized_brand,
    model,
    mpn,
    upc,
    gtin,
    root_category,
    product_category,
    category_urls,
    breadcrumbs,
    final_price,
    initial_price,
    offer_price,
    sale_price,
    effective_price,
    currency_code,
    price_text,
    discount,
    availability,
    availability_new,
    offer_status,
    rating,
    amount_of_stars,
    reviews_count,
    questions_count,
    recommend_percentage,
    hot_offer,
    open_box,
    image_url,
    images,
    customer_images,
    esrb_rating,
    highlights,
    features_summary,
    features,
    whats_included,
    product_description,
    product_specifications,
    q_a,
    reviews,
    you_maight_also_need,
    customers_ultimately_bought,
    deals_on_realated_items,
    frequently_bought_with,
    seller_name,
    seller_url,
    seller_json,
    store_name,
    store_country,
    seller_privacy_policy,
    seller_tos,
    return_policy,
    return_window,
    target_countries,
    listing_has_variations,
    variation,
    variations,
    variant_attributes,
    variants,
    source_dataset,
    parser_version,
    promotion_status,
    parsed_payload,
    payload_hash
  )
  values (
    p_raw_capture_id,
    v_collection_run_id,
    v_platform_id,
    v_product_id,
    coalesce(p_payload->>'sku', p_payload->>'skuId', p_payload->>'sku_id', v_product_id),
    v_url,
    v_title,
    lower(v_title),
    p_payload->>'brand',
    lower(p_payload->>'brand'),
    coalesce(p_payload->>'model', p_payload->>'model_number'),
    p_payload->>'mpn',
    p_payload->>'upc',
    coalesce(p_payload->>'gtin', p_payload->>'upc'),
    p_payload->>'root_category',
    coalesce(p_payload->>'product_category', p_payload->>'category_path'),
    coalesce(p_payload->'category_urls', '[]'::jsonb),
    coalesce(p_payload->'breadcrumbs', '[]'::jsonb),
    retail.safe_numeric(coalesce(p_payload->>'final_price', p_payload->>'price')),
    retail.safe_numeric(p_payload->>'initial_price'),
    retail.safe_numeric(p_payload->>'offer_price'),
    retail.safe_numeric(p_payload->>'sale_price'),
    coalesce(
      retail.safe_numeric(p_payload->>'final_price'),
      retail.safe_numeric(p_payload->>'offer_price'),
      retail.safe_numeric(p_payload->>'sale_price'),
      retail.safe_numeric(p_payload->>'price')
    ),
    coalesce(nullif(p_payload->>'currency',''), 'USD')::char(3),
    p_payload->>'price_text',
    p_payload->>'discount',
    p_payload->>'availability',
    p_payload->>'availability_new',
    case
      when lower(coalesce(p_payload->>'availability', p_payload->>'availability_new', '')) like '%out%' then 'out_of_stock'::retail.bestbuy_offer_status
      when lower(coalesce(p_payload->>'availability', p_payload->>'availability_new', '')) like '%limited%' then 'limited'::retail.bestbuy_offer_status
      when coalesce(p_payload->>'availability', p_payload->>'availability_new', '') <> '' then 'available'::retail.bestbuy_offer_status
      else 'unknown'::retail.bestbuy_offer_status
    end,
    retail.safe_numeric(coalesce(p_payload->>'rating', p_payload->>'amount_of_stars')),
    retail.safe_numeric(coalesce(p_payload->>'amount_of_stars', p_payload->>'rating')),
    retail.safe_integer(coalesce(p_payload->>'reviews_count', p_payload->>'review_count')),
    retail.safe_integer(p_payload->>'questions_count'),
    retail.safe_numeric(p_payload->>'recommend_percentage'),
    retail.safe_boolean(p_payload->>'hot_offer'),
    retail.safe_boolean(p_payload->>'open_box'),
    coalesce(p_payload->>'image_url', p_payload->>'main_image'),
    coalesce(p_payload->'images', p_payload->'image_urls', '[]'::jsonb),
    coalesce(p_payload->'customer_images', '[]'::jsonb),
    p_payload->>'esrb_rating',
    coalesce(p_payload->'highlights', '[]'::jsonb),
    p_payload->>'features_summary',
    coalesce(p_payload->'features', '[]'::jsonb),
    coalesce(p_payload->'whats_included', '[]'::jsonb),
    coalesce(p_payload->>'product_description', p_payload->>'description'),
    coalesce(p_payload->'product_specifications', p_payload->'specifications', '[]'::jsonb),
    coalesce(p_payload->'q_a', '[]'::jsonb),
    coalesce(p_payload->'reviews', p_payload->'customer_reviews', '[]'::jsonb),
    coalesce(p_payload->'you_maight_also_need', '[]'::jsonb),
    coalesce(p_payload->'customers_ultimately_bought', '[]'::jsonb),
    coalesce(p_payload->'deals_on_realated_items', '[]'::jsonb),
    coalesce(p_payload->'frequently_bought_with', '[]'::jsonb),
    coalesce(p_payload->>'seller_name', p_payload->>'seller'),
    p_payload->>'seller_url',
    coalesce(p_payload->'seller_json', p_payload->'seller_info', '{}'::jsonb),
    p_payload->>'store_name',
    p_payload->>'store_country',
    p_payload->>'seller_privacy_policy',
    p_payload->>'seller_tos',
    p_payload->>'return_policy',
    retail.safe_integer(p_payload->>'return_window'),
    coalesce(p_payload->'target_countries', '[]'::jsonb),
    retail.safe_boolean(p_payload->>'listing_has_variations'),
    coalesce(p_payload->'variation', '{}'::jsonb),
    coalesce(p_payload->'variations', '[]'::jsonb),
    coalesce(p_payload->'variant_attributes', '{}'::jsonb),
    coalesce(p_payload->'variants', '[]'::jsonb),
    'brightdata_bestbuy',
    'brightdata_bestbuy_v1',
    'not_promoted'::retail.bestbuy_promotion_status,
    p_payload,
    v_payload_hash
  )
  on conflict (platform_id, product_id, raw_capture_id)
  do update set
    sku = excluded.sku,
    url = excluded.url,
    title = excluded.title,
    normalized_title = excluded.normalized_title,
    brand = excluded.brand,
    normalized_brand = excluded.normalized_brand,
    final_price = excluded.final_price,
    effective_price = excluded.effective_price,
    currency_code = excluded.currency_code,
    availability = excluded.availability,
    offer_status = excluded.offer_status,
    rating = excluded.rating,
    amount_of_stars = excluded.amount_of_stars,
    reviews_count = excluded.reviews_count,
    image_url = excluded.image_url,
    images = excluded.images,
    parsed_payload = excluded.parsed_payload,
    payload_hash = excluded.payload_hash,
    updated_at = now()
  returning id into v_parsed_id;

  delete from retail.bestbuy_product_images where bestbuy_parsed_id = v_parsed_id;
  delete from retail.bestbuy_product_specifications where bestbuy_parsed_id = v_parsed_id;

  v_idx := 1;
  for v_image in
    select * from jsonb_array_elements(coalesce(p_payload->'images', p_payload->'image_urls', '[]'::jsonb))
  loop
    insert into retail.bestbuy_product_images (
      bestbuy_parsed_id,
      image_url,
      image_rank,
      is_main
    )
    values (
      v_parsed_id,
      trim(both '"' from v_image::text),
      v_idx,
      trim(both '"' from v_image::text) = coalesce(p_payload->>'image_url', p_payload->>'main_image')
    )
    on conflict do nothing;

    v_idx := v_idx + 1;
  end loop;

  for v_spec in
    select * from jsonb_array_elements(coalesce(p_payload->'product_specifications', p_payload->'specifications', '[]'::jsonb))
  loop
    insert into retail.bestbuy_product_specifications (
      bestbuy_parsed_id,
      specification_name,
      specification_value,
      normalized_specification_name
    )
    values (
      v_parsed_id,
      coalesce(v_spec->>'name', v_spec->>'specification_name'),
      coalesce(v_spec->>'value', v_spec->>'specification_value'),
      lower(coalesce(v_spec->>'name', v_spec->>'specification_name'))
    )
    on conflict do nothing;
  end loop;

  return v_parsed_id;
end;
$function$;

create or replace function retail.promote_bestbuy_parsed_product(
  p_bestbuy_parsed_id uuid
)
returns uuid
language plpgsql
as $function$
declare
  v_parsed retail.bestbuy_product_parsed%rowtype;
  v_retail_product_id uuid;
  v_offer_snapshot_id uuid;
  v_availability retail.product_availability;
begin
  select *
  into v_parsed
  from retail.bestbuy_product_parsed
  where id = p_bestbuy_parsed_id;

  if v_parsed.id is null then
    raise exception 'Best Buy parsed product not found: %', p_bestbuy_parsed_id;
  end if;

  v_availability :=
    case v_parsed.offer_status
      when 'available' then 'in_stock'::retail.product_availability
      when 'limited' then 'limited_stock'::retail.product_availability
      when 'out_of_stock' then 'out_of_stock'::retail.product_availability
      else 'unknown'::retail.product_availability
    end;

  insert into retail.retail_products (
    platform_id,
    platform_product_key,
    source_url,
    title,
    brand,
    model_number,
    upc,
    sku,
    category_path,
    image_url,
    first_seen_at,
    last_seen_at,
    is_active,
    normalized_json
  )
  values (
    v_parsed.platform_id,
    v_parsed.product_id,
    v_parsed.url,
    v_parsed.title,
    v_parsed.brand,
    v_parsed.model,
    v_parsed.upc,
    v_parsed.sku,
    v_parsed.product_category,
    v_parsed.image_url,
    now(),
    now(),
    true,
    v_parsed.parsed_payload
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
    coalesce(v_parsed.effective_price, v_parsed.final_price, v_parsed.offer_price, v_parsed.sale_price),
    v_availability,
    null,
    null,
    null,
    v_parsed.url,
    v_parsed.raw_capture_id,
    jsonb_build_object(
      'source', 'brightdata',
      'retailer', 'best_buy',
      'currency', coalesce(v_parsed.currency_code::text, 'USD'),
      'parsed_id', v_parsed.id,
      'rating', v_parsed.rating,
      'reviews_count', v_parsed.reviews_count
    )
  );

  update retail.bestbuy_product_parsed
  set promotion_status = 'promoted'::retail.bestbuy_promotion_status,
      promoted_retail_product_id = v_retail_product_id,
      promoted_offer_snapshot_id = v_offer_snapshot_id,
      promoted_at = now(),
      promotion_error = null,
      updated_at = now()
  where id = v_parsed.id;

  return v_retail_product_id;
exception
  when others then
    update retail.bestbuy_product_parsed
    set promotion_status = 'failed'::retail.bestbuy_promotion_status,
        promotion_error = sqlerrm,
        updated_at = now()
    where id = p_bestbuy_parsed_id;

    raise;
end;
$function$;
