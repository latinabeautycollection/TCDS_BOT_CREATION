CREATE OR REPLACE FUNCTION retail.record_offer_snapshot(p_retail_product_id uuid, p_effective_price numeric, p_availability retail.product_availability, p_quantity_available integer DEFAULT NULL::integer, p_shipping_cost_estimate numeric DEFAULT NULL::numeric, p_estimated_tax numeric DEFAULT NULL::numeric, p_source_url text DEFAULT NULL::text, p_raw_capture_id uuid DEFAULT NULL::uuid, p_offer_metadata jsonb DEFAULT '{}'::jsonb)
 RETURNS uuid
 LANGUAGE plpgsql
AS $function$
declare
  v_platform_id uuid;
  v_source_url text;
  v_estimated_total numeric;
  v_offer_hash text;
  v_offer_id uuid;
begin
  if p_retail_product_id is null then
    raise exception 'retail_product_id is required';
  end if;

  if p_effective_price is null or p_effective_price < 0 then
    raise exception 'effective_price must be non-negative';
  end if;

  select platform_id, source_url
  into v_platform_id, v_source_url
  from retail.retail_products
  where id = p_retail_product_id;

  if v_platform_id is null then
    raise exception 'Retail product not found: %', p_retail_product_id;
  end if;

  v_source_url := coalesce(nullif(trim(coalesce(p_source_url,'')), ''), v_source_url);

  v_estimated_total :=
    p_effective_price
    + coalesce(p_shipping_cost_estimate, 0)
    + coalesce(p_estimated_tax, 0);

  v_offer_hash := encode(
    digest(
      p_retail_product_id::text || '|' ||
      p_effective_price::text || '|' ||
      p_availability::text || '|' ||
      coalesce(p_quantity_available::text, '') || '|' ||
      coalesce(p_shipping_cost_estimate::text, '') || '|' ||
      coalesce(p_estimated_tax::text, '') || '|' ||
      coalesce(v_source_url, '') || '|' ||
      coalesce(p_offer_metadata::text, ''),
      'sha256'
    ),
    'hex'
  );

  insert into retail.retail_offer_snapshots (
    retail_product_id,
    platform_id,
    effective_price,
    availability,
    quantity_available,
    shipping_cost_estimate,
    estimated_tax,
    estimated_total_cost,
    source_url,
    raw_capture_id,
    offer_hash,
    offer_metadata
  )
  values (
    p_retail_product_id,
    v_platform_id,
    p_effective_price,
    p_availability,
    p_quantity_available,
    p_shipping_cost_estimate,
    p_estimated_tax,
    v_estimated_total,
    v_source_url,
    p_raw_capture_id,
    v_offer_hash,
    coalesce(p_offer_metadata, '{}'::jsonb)
  )
  on conflict (retail_product_id, offer_hash)
  do update set
    raw_capture_id = coalesce(excluded.raw_capture_id, retail.retail_offer_snapshots.raw_capture_id),
    offer_metadata = retail.retail_offer_snapshots.offer_metadata || excluded.offer_metadata
  returning id into v_offer_id;

  insert into retail.product_price_history (
    retail_product_id,
    platform_id,
    effective_price,
    raw_capture_id,
    price_metadata
  )
  values (
    p_retail_product_id,
    v_platform_id,
    p_effective_price,
    p_raw_capture_id,
    coalesce(p_offer_metadata, '{}'::jsonb)
  );

  insert into retail.product_inventory_history (
    retail_product_id,
    platform_id,
    availability,
    quantity_available,
    raw_capture_id,
    inventory_metadata
  )
  values (
    p_retail_product_id,
    v_platform_id,
    p_availability,
    p_quantity_available,
    p_raw_capture_id,
    coalesce(p_offer_metadata, '{}'::jsonb)
  );

  insert into retail.current_retail_offers (
    retail_product_id,
    platform_id,
    latest_offer_snapshot_id,
    effective_price,
    currency_code,
    availability,
    quantity_available,
    shipping_cost_estimate,
    estimated_tax,
    estimated_total_cost,
    source_url,
    first_seen_at,
    last_seen_at,
    seen_count,
    offer_metadata
  )
  values (
    p_retail_product_id,
    v_platform_id,
    v_offer_id,
    p_effective_price,
    coalesce(p_offer_metadata->>'currency', 'USD')::char(3),
    p_availability,
    p_quantity_available,
    p_shipping_cost_estimate,
    p_estimated_tax,
    v_estimated_total,
    v_source_url,
    now(),
    now(),
    1,
    coalesce(p_offer_metadata, '{}'::jsonb)
  )
  on conflict (retail_product_id)
  do update set
    latest_offer_snapshot_id = excluded.latest_offer_snapshot_id,
    effective_price = excluded.effective_price,
    currency_code = excluded.currency_code,
    availability = excluded.availability,
    quantity_available = excluded.quantity_available,
    shipping_cost_estimate = excluded.shipping_cost_estimate,
    estimated_tax = excluded.estimated_tax,
    estimated_total_cost = excluded.estimated_total_cost,
    source_url = excluded.source_url,
    last_seen_at = now(),
    seen_count = retail.current_retail_offers.seen_count + 1,
    offer_metadata = excluded.offer_metadata,
    updated_at = now();

  return v_offer_id;
end;
$function$

