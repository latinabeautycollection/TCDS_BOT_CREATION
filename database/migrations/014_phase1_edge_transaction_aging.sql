CREATE TABLE IF NOT EXISTS pqp.pqp_edge_http_events (
  id BIGSERIAL PRIMARY KEY,
  session_id UUID,
  profile_name TEXT,
  ip INET,
  ja3 TEXT,
  ja4 TEXT,
  tls_version TEXT,
  cipher_suite TEXT,
  sni TEXT,
  alpn TEXT,
  http_version TEXT,
  h2_settings JSONB DEFAULT '{}'::jsonb,
  pseudo_header_order TEXT[] DEFAULT ARRAY[]::TEXT[],
  header_order TEXT[] DEFAULT ARRAY[]::TEXT[],
  session_resumed BOOLEAN,
  raw JSONB DEFAULT '{}'::jsonb,
  created_at TIMESTAMPTZ DEFAULT now()
);

CREATE TABLE IF NOT EXISTS pqp.pqp_transaction_events (
  id BIGSERIAL PRIMARY KEY,
  session_id UUID,
  profile_name TEXT,
  event_type TEXT,
  page TEXT,
  duration_ms INTEGER,
  metadata JSONB DEFAULT '{}'::jsonb,
  created_at TIMESTAMPTZ DEFAULT now()
);

CREATE TABLE IF NOT EXISTS pqp.pqp_profile_aging_events (
  id BIGSERIAL PRIMARY KEY,
  session_id UUID,
  profile_name TEXT,
  cookie_age_ms BIGINT,
  local_storage_age_ms BIGINT,
  indexeddb_age_ms BIGINT,
  service_worker_age_ms BIGINT,
  cache_age_ms BIGINT,
  profile_first_seen_at TIMESTAMPTZ,
  raw JSONB DEFAULT '{}'::jsonb,
  created_at TIMESTAMPTZ DEFAULT now()
);

CREATE TABLE IF NOT EXISTS pqp.pqp_fingerprint_collisions (
  id BIGSERIAL PRIMARY KEY,
  signal_name TEXT NOT NULL,
  signal_value TEXT,
  affected_profiles JSONB DEFAULT '[]'::jsonb,
  created_at TIMESTAMPTZ DEFAULT now()
);

ALTER TABLE pqp.pqp_phase4_score_history
  ADD COLUMN IF NOT EXISTS transaction_score INTEGER,
  ADD COLUMN IF NOT EXISTS population_risk_score INTEGER;
