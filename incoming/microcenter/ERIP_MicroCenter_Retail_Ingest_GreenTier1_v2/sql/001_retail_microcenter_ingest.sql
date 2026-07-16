begin;

create schema if not exists retail;

create table if not exists retail.platforms (
  platform_id uuid primary key default gen_random_uuid(),
  platform_code text not null unique,
  platform_name text not null,
  platform_type text not null default 'retailer',
  is_enabled boolean not null default true,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table if not exists retail.collection_runs (
  collection_run_id uuid primary key,
  platform_id uuid not null references retail.platforms(platform_id),
  dataset_id text not null,
  snapshot_id text,
  run_key text not null unique,
  status text not null,
  requested_input_count integer not null default 0,
  received_record_count integer not null default 0,
  inserted_raw_count integer not null default 0,
  inserted_offer_count integer not null default 0,
  duplicate_count integer not null default 0,
  quarantine_count integer not null default 0,
  estimated_cost numeric(14,6),
  actual_cost numeric(14,6),
  request_payload jsonb not null default '{}'::jsonb,
  provider_response jsonb not null default '{}'::jsonb,
  metrics jsonb not null default '{}'::jsonb,
  error_code text,
  error_message text,
  worker_id text,
  environment text,
  started_at timestamptz not null default now(),
  completed_at timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create unique index if not exists ux_collection_runs_snapshot
  on retail.collection_runs(snapshot_id)
  where snapshot_id is not null;

create index if not exists ix_collection_runs_platform_started
  on retail.collection_runs(platform_id, started_at desc);

create table if not exists retail.raw_product_captures (
  raw_capture_id uuid primary key,
  collection_run_id uuid not null references retail.collection_runs(collection_run_id) on delete cascade,
  platform_id uuid not null references retail.platforms(platform_id),
  source_record_hash text not null,
  source_position integer,
  source_url text,
  payload jsonb not null,
  observed_at timestamptz not null,
  created_at timestamptz not null default now(),
  unique(platform_id, source_record_hash)
);

create index if not exists ix_raw_product_captures_run
  on retail.raw_product_captures(collection_run_id);

create table if not exists retail.retail_products (
  retail_product_id uuid primary key,
  platform_id uuid not null references retail.platforms(platform_id),
  retailer_product_key text not null,
  retailer_sku text,
  upc text,
  gtin text,
  mpn text,
  brand text,
  model text,
  title text not null,
  product_url text,
  image_url text,
  category_text text,
  condition_text text,
  seller_name text,
  identity_confidence numeric(6,5) not null default 0,
  first_seen_at timestamptz not null,
  last_seen_at timestamptz not null,
  latest_payload jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique(platform_id, retailer_product_key)
);

create index if not exists ix_retail_products_upc
  on retail.retail_products(upc)
  where upc is not null;

create index if not exists ix_retail_products_brand_model
  on retail.retail_products(lower(brand), lower(model));

create table if not exists retail.retail_offer_snapshots (
  retail_offer_snapshot_id uuid primary key,
  collection_run_id uuid not null references retail.collection_runs(collection_run_id) on delete cascade,
  platform_id uuid not null references retail.platforms(platform_id),
  retail_product_id uuid not null references retail.retail_products(retail_product_id),
  source_record_hash text not null,
  currency_code text not null default 'USD',
  current_price numeric(14,2),
  original_price numeric(14,2),
  shipping_cost numeric(14,2),
  in_stock boolean,
  stock_text text,
  store_id text,
  store_name text,
  rating numeric(6,3),
  review_count integer,
  evidence_confidence numeric(6,5) not null,
  observed_at timestamptz not null,
  payload jsonb not null,
  created_at timestamptz not null default now(),
  unique(platform_id, source_record_hash)
);

create index if not exists ix_retail_offer_snapshots_product_time
  on retail.retail_offer_snapshots(retail_product_id, observed_at desc);

create table if not exists retail.product_price_history (
  price_history_id uuid primary key,
  platform_id uuid not null references retail.platforms(platform_id),
  retail_product_id uuid not null references retail.retail_products(retail_product_id),
  retail_offer_snapshot_id uuid not null references retail.retail_offer_snapshots(retail_offer_snapshot_id),
  currency_code text not null,
  current_price numeric(14,2),
  original_price numeric(14,2),
  shipping_cost numeric(14,2),
  observed_at timestamptz not null,
  created_at timestamptz not null default now(),
  unique(retail_offer_snapshot_id)
);

create table if not exists retail.product_inventory_history (
  inventory_history_id uuid primary key,
  platform_id uuid not null references retail.platforms(platform_id),
  retail_product_id uuid not null references retail.retail_products(retail_product_id),
  retail_offer_snapshot_id uuid not null references retail.retail_offer_snapshots(retail_offer_snapshot_id),
  in_stock boolean,
  stock_text text,
  store_id text,
  store_name text,
  observed_at timestamptz not null,
  created_at timestamptz not null default now(),
  unique(retail_offer_snapshot_id)
);

create table if not exists retail.data_quality_events (
  data_quality_event_id uuid primary key,
  collection_run_id uuid not null references retail.collection_runs(collection_run_id) on delete cascade,
  platform_id uuid not null references retail.platforms(platform_id),
  source_position integer,
  severity text not null,
  event_code text not null,
  event_message text not null,
  payload jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now()
);

create index if not exists ix_data_quality_events_run
  on retail.data_quality_events(collection_run_id, severity);

create table if not exists retail.platform_health_rollups (
  platform_health_rollup_id uuid primary key,
  platform_id uuid not null references retail.platforms(platform_id),
  rollup_date date not null,
  run_count integer not null default 0,
  successful_run_count integer not null default 0,
  failed_run_count integer not null default 0,
  received_record_count bigint not null default 0,
  offer_count bigint not null default 0,
  quarantine_count bigint not null default 0,
  duplicate_count bigint not null default 0,
  success_rate numeric(8,5),
  quarantine_rate numeric(8,5),
  updated_at timestamptz not null default now(),
  unique(platform_id, rollup_date)
);

insert into retail.platforms(platform_code, platform_name)
values ('microcenter', 'Micro Center')
on conflict (platform_code) do update
set platform_name = excluded.platform_name,
    updated_at = now();

commit;
