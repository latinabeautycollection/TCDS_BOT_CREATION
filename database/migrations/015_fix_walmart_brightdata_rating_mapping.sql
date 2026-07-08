CREATE OR REPLACE FUNCTION retail.ingest_brightdata_walmart_product(p_raw_capture_id uuid, p_payload jsonb)
 RETURNS uuid
 LANGUAGE plpgsql
AS $function$
declare
  v_platform_id uuid;
  v_raw_platform_id uuid;
  v_collection_run_id uuid;
  v_parsed_id uuid;
  v_payload_hash text;
  v_walmart_product_id text;
  v_product_name text;
  v_url text;
  v_image jsonb;
  v_spec jsonb;
  v_category jsonb;
  v_seller jsonb;
  v_variant jsonb;
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
  where platform_code = 'walmart';

  if v_platform_id is null then
    raise exception 'Walmart platform not found in retail.retail_platforms';
  end if;

  select platform_id, collection_run_id
  into v_raw_platform_id, v_collection_run_id
  from retail.raw_product_captures
  where id = p_raw_capture_id;

  if v_raw_platform_id is null then
    raise exception 'Raw capture not found: %', p_raw_capture_id;
  end if;

  if v_raw_platform_id <> v_platform_id then
    raise exception 'Raw capture % is not a Walmart capture', p_raw_capture_id;
  end if;

  v_walmart_product_id :=
    nullif(trim(coalesce(
      p_payload->>'product_id',
      p_payload->>'sku',
      p_payload#>>'{product_identifiers,id}',
      p_payload#>>'{product_identifiers,us_item_id}'
    )), '');

  v_product_name :=
    nullif(trim(coalesce(
      p_payload->>'product_name',
      p_payload->>'short_description',
      p_payload->>'title'
    )), '');

  v_url :=
    nullif(trim(coalesce(
      p_payload->>'url',
      case when v_walmart_product_id is not null
        then 'https://www.walmart.com/ip/' || v_walmart_product_id
        else null
      end
    )), '');

  if v_walmart_product_id is null then
    raise exception 'Missing Walmart product_id/sku/us_item_id';
  end if;

  if v_product_name is null then
    raise exception 'Missing Walmart product_name/short_description';
  end if;

  if v_url is null then
    raise exception 'Missing Walmart product URL';
  end if;

  v_payload_hash := encode(digest(p_payload::text, 'sha256'), 'hex');

  insert into retail.walmart_product_parsed (
    raw_capture_id,
    collection_run_id,
    platform_id,

    walmart_product_id,
    sku,
    us_item_id,
    group_id,
    variant_id,

    url,
    product_name,
    short_description,
    description,

    brand,
    model_number,
    mpn,
    upc,
    gtin,
    condition,

    final_price,
    initial_price,
    sale_price,
    currency_code,
    price_text,
    discount,
    price_range,

    availability,
    availability_text,
    offer_status,
    is_available,
    available_for_delivery,
    available_for_pickup,

    shipping_availability_date,
    max_shipping_availability_date,
    store_delivery_date,
    max_store_delivery_date,

    category_name,
    category_path,
    category_ids,
    product_category,
    root_category_name,
    root_category_url,
    breadcrumb_text,

    main_image,

    rating_stars,
    rating_count,
    review_count,
    reviews_count,

    seller_id,
    seller_name,
    seller_url,

    store_id,
    store_name,
    store_location,
    store_country,

    fulfillment_type,
    free_returns,
    is_returnable,
    return_policy,
    return_window,

    order_limit,
    listing_has_variations,

    parsed_payload,
    payload_hash
  )
  values (
    p_raw_capture_id,
    v_collection_run_id,
    v_platform_id,

    v_walmart_product_id,
    p_payload->>'sku',
    p_payload#>>'{product_identifiers,us_item_id}',
    p_payload->>'group_id',
    p_payload->>'variant_id',

    v_url,
    v_product_name,
    p_payload->>'short_description',
    p_payload->>'description',

    p_payload->>'brand',
    coalesce(p_payload#>>'{product_identifiers,model}', p_payload->>'mpn'),
    p_payload->>'mpn',
    coalesce(p_payload->>'upc', p_payload#>>'{product_identifiers,upc}'),
    coalesce(p_payload->>'gtin', p_payload->>'upc', p_payload#>>'{product_identifiers,upc}'),
    p_payload->>'condition',

    retail.safe_numeric(p_payload->>'final_price'),
    retail.safe_numeric(p_payload->>'initial_price'),
    retail.safe_numeric(p_payload->>'sale_price'),
    coalesce(nullif(p_payload->>'currency',''), 'USD')::char(3),
    p_payload->>'price',
    p_payload->>'discount',
    p_payload->'price_range',

    p_payload->>'availability',
    p_payload->>'availability_text',
    retail.normalize_walmart_offer_status(
      retail.safe_boolean(p_payload->>'is_available'),
      p_payload->>'availability',
      p_payload->>'availability_text'
    ),
    retail.safe_boolean(p_payload->>'is_available'),
    retail.safe_boolean(p_payload->>'available_for_delivery'),
    retail.safe_boolean(p_payload->>'available_for_pickup'),

    retail.safe_timestamptz(p_payload->>'shipping_availability_date'),
    retail.safe_timestamptz(p_payload->>'max_shipping_availability_date'),
    retail.safe_timestamptz(p_payload->>'store_delivery_date'),
    retail.safe_timestamptz(p_payload->>'max_store_delivery_date'),

    p_payload->>'category_name',
    p_payload->>'category_path',
    p_payload->>'category_ids',
    coalesce(p_payload->>'product_category', p_payload->>'breadcrumb_text'),
    p_payload->>'root_category_name',
    p_payload->>'root_category_url',
    p_payload->>'breadcrumb_text',

    p_payload->>'main_image',

    retail.safe_numeric(p_payload->>'rating'),
    retail.safe_integer(p_payload->>'rating_count'),
    retail.safe_integer(p_payload->>'review_count'),
    retail.safe_integer(p_payload->>'reviews_count'),

    coalesce(p_payload->>'seller_id', p_payload#>>'{seller_info,0,seller_id}'),
    coalesce(p_payload#>>'{seller_info,0,seller_name}', p_payload->>'seller'),
    coalesce(p_payload->>'seller_url', p_payload#>>'{seller_info,0,seller_url}'),

    retail.safe_integer(p_payload->>'store_id'),
    p_payload->>'store_name',
    p_payload->>'store_location',
    p_payload->>'store_country',

    coalesce(p_payload->>'Fulfillment_type', p_payload->>'fulfillment_type'),
    retail.safe_boolean(p_payload->>'free_returns'),
    retail.safe_boolean(p_payload->>'is_returnable'),
    p_payload->>'return_policy',
    p_payload->>'return_window',

    retail.safe_integer(p_payload->>'order_limit'),
    retail.safe_boolean(p_payload->>'listing_has_variations'),

    p_payload,
    v_payload_hash
  )
  on conflict (platform_id, walmart_product_id, raw_capture_id)
  do update set
    sku = excluded.sku,
    us_item_id = excluded.us_item_id,
    group_id = excluded.group_id,
    variant_id = excluded.variant_id,
    url = excluded.url,
    product_name = excluded.product_name,
    short_description = excluded.short_description,
    description = excluded.description,
    brand = excluded.brand,
    model_number = excluded.model_number,
    mpn = excluded.mpn,
    upc = excluded.upc,
    gtin = excluded.gtin,
    condition = excluded.condition,
    final_price = excluded.final_price,
    initial_price = excluded.initial_price,
    sale_price = excluded.sale_price,
    currency_code = excluded.currency_code,
    price_text = excluded.price_text,
    discount = excluded.discount,
    price_range = excluded.price_range,
    availability = excluded.availability,
    availability_text = excluded.availability_text,
    offer_status = excluded.offer_status,
    is_available = excluded.is_available,
    available_for_delivery = excluded.available_for_delivery,
    available_for_pickup = excluded.available_for_pickup,
    category_name = excluded.category_name,
    category_path = excluded.category_path,
    category_ids = excluded.category_ids,
    product_category = excluded.product_category,
    root_category_name = excluded.root_category_name,
    root_category_url = excluded.root_category_url,
    breadcrumb_text = excluded.breadcrumb_text,
    main_image = excluded.main_image,
    rating_stars = excluded.rating_stars,
    rating_count = excluded.rating_count,
    review_count = excluded.review_count,
    reviews_count = excluded.reviews_count,
    seller_id = excluded.seller_id,
    seller_name = excluded.seller_name,
    seller_url = excluded.seller_url,
    store_id = excluded.store_id,
    store_name = excluded.store_name,
    store_location = excluded.store_location,
    store_country = excluded.store_country,
    fulfillment_type = excluded.fulfillment_type,
    free_returns = excluded.free_returns,
    is_returnable = excluded.is_returnable,
    return_policy = excluded.return_policy,
    return_window = excluded.return_window,
    order_limit = excluded.order_limit,
    listing_has_variations = excluded.listing_has_variations,
    parsed_payload = excluded.parsed_payload,
    payload_hash = excluded.payload_hash,
    updated_at = now()
  returning id into v_parsed_id;

  delete from retail.walmart_product_images where walmart_parsed_id = v_parsed_id;
  delete from retail.walmart_product_specifications where walmart_parsed_id = v_parsed_id;
  delete from retail.walmart_product_categories where walmart_parsed_id = v_parsed_id;
  delete from retail.walmart_product_sellers where walmart_parsed_id = v_parsed_id;
  delete from retail.walmart_product_variants where walmart_parsed_id = v_parsed_id;
  delete from retail.walmart_product_reviews_summary where walmart_parsed_id = v_parsed_id;

  v_idx := 1;
  for v_image in
    select * from jsonb_array_elements(coalesce(p_payload->'image_urls','[]'::jsonb))
  loop
    insert into retail.walmart_product_images (
      walmart_parsed_id,
      image_url,
      image_rank,
      is_main
    )
    values (
      v_parsed_id,
      trim(both '"' from v_image::text),
      v_idx,
      trim(both '"' from v_image::text) = p_payload->>'main_image'
    )
    on conflict do nothing;

    v_idx := v_idx + 1;
  end loop;

  if p_payload ? 'main_image' and nullif(p_payload->>'main_image','') is not null then
    insert into retail.walmart_product_images (
      walmart_parsed_id,
      image_url,
      image_rank,
      is_main
    )
    values (
      v_parsed_id,
      p_payload->>'main_image',
      1,
      true
    )
    on conflict do nothing;
  end if;

  for v_spec in
    select * from jsonb_array_elements(coalesce(p_payload->'specifications','[]'::jsonb))
  loop
    if nullif(v_spec->>'name','') is not null then
      insert into retail.walmart_product_specifications (
        walmart_parsed_id,
        spec_name,
        spec_value
      )
      values (
        v_parsed_id,
        v_spec->>'name',
        v_spec->>'value'
      )
      on conflict do nothing;
    end if;
  end loop;

  v_idx := 1;
  for v_category in
    select * from jsonb_array_elements(coalesce(p_payload->'breadcrumbs','[]'::jsonb))
  loop
    if nullif(v_category->>'name','') is not null then
      insert into retail.walmart_product_categories (
        walmart_parsed_id,
        category_rank,
        category_name,
        category_url
      )
      values (
        v_parsed_id,
        v_idx,
        v_category->>'name',
        v_category->>'url'
      )
      on conflict do nothing;

      v_idx := v_idx + 1;
    end if;
  end loop;

  for v_seller in
    select * from jsonb_array_elements(coalesce(p_payload->'seller_info','[]'::jsonb))
  loop
    insert into retail.walmart_product_sellers (
      walmart_parsed_id,
      seller_id,
      seller_name,
      seller_url
    )
    values (
      v_parsed_id,
      v_seller->>'seller_id',
      v_seller->>'seller_name',
      v_seller->>'seller_url'
    )
    on conflict do nothing;
  end loop;

  for v_variant in
    select * from jsonb_array_elements(coalesce(p_payload->'variants','[]'::jsonb))
  loop
    insert into retail.walmart_product_variants (
      walmart_parsed_id,
      variant_id,
      variant_json
    )
    values (
      v_parsed_id,
      coalesce(v_variant->>'variant_id', v_variant->>'id'),
      v_variant
    );
  end loop;

  insert into retail.walmart_product_reviews_summary (
    walmart_parsed_id,
    rating_stars,
    rating_count,
    review_count,
    reviews_count,
    top_reviews,
    customer_reviews,
    review_tags,
    review_images,
    review_videos
  )
  values (
    v_parsed_id,
    retail.safe_numeric(p_payload->>'rating'),
    retail.safe_integer(p_payload->>'rating_count'),
    retail.safe_integer(p_payload->>'review_count'),
    retail.safe_integer(p_payload->>'reviews_count'),
    p_payload->'top_reviews',
    coalesce(p_payload->'customer_reviews','[]'::jsonb),
    p_payload->'review_tags',
    coalesce(p_payload->'review_images','[]'::jsonb),
    coalesce(p_payload->'review_videos','[]'::jsonb)
  )
  on conflict (walmart_parsed_id)
  do update set
    rating_stars = excluded.rating_stars,
    rating_count = excluded.rating_count,
    review_count = excluded.review_count,
    reviews_count = excluded.reviews_count,
    top_reviews = excluded.top_reviews,
    customer_reviews = excluded.customer_reviews,
    review_tags = excluded.review_tags,
    review_images = excluded.review_images,
    review_videos = excluded.review_videos;

  return v_parsed_id;
end;
$function$

