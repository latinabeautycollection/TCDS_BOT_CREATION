BEGIN;

CREATE TABLE IF NOT EXISTS pqp.pqp_transaction_events (
  id BIGSERIAL PRIMARY KEY,
  session_id UUID REFERENCES pqp.pqp_sessions(id) ON DELETE CASCADE,
  profile_name TEXT,
  event_type TEXT,
  page TEXT,
  duration_ms INT,
  metadata JSONB DEFAULT '{}'::jsonb,
  created_at TIMESTAMPTZ DEFAULT now()
);

CREATE TABLE IF NOT EXISTS pqp.pqp_profile_aging_events (
  id BIGSERIAL PRIMARY KEY,
  session_id UUID REFERENCES pqp.pqp_sessions(id) ON DELETE CASCADE,
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

CREATE INDEX IF NOT EXISTS idx_pqp_transaction_events_session ON pqp.pqp_transaction_events(session_id);
CREATE INDEX IF NOT EXISTS idx_pqp_transaction_events_profile ON pqp.pqp_transaction_events(profile_name);
CREATE INDEX IF NOT EXISTS idx_pqp_transaction_events_type ON pqp.pqp_transaction_events(event_type);
CREATE INDEX IF NOT EXISTS idx_pqp_transaction_events_created ON pqp.pqp_transaction_events(created_at DESC);

CREATE INDEX IF NOT EXISTS idx_pqp_profile_aging_session ON pqp.pqp_profile_aging_events(session_id);
CREATE INDEX IF NOT EXISTS idx_pqp_profile_aging_profile ON pqp.pqp_profile_aging_events(profile_name);
CREATE INDEX IF NOT EXISTS idx_pqp_profile_aging_created ON pqp.pqp_profile_aging_events(created_at DESC);

COMMIT;
