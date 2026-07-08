alter table retail.erip_source_exports
  add column if not exists updated_at timestamptz default now();
