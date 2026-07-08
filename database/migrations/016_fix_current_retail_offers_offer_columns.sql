alter table retail.current_retail_offers
  add column if not exists currency_code char(3) default 'USD',
  add column if not exists shipping_cost_estimate numeric(12,2),
  add column if not exists estimated_tax numeric(12,2),
  add column if not exists source_url text,
  add column if not exists offer_metadata jsonb default '{}'::jsonb;
