CREATE EXTENSION IF NOT EXISTS pgcrypto;
CREATE SCHEMA IF NOT EXISTS pqp;

CREATE TABLE IF NOT EXISTS pqp.pqp_ip_reputation (
  id BIGSERIAL PRIMARY KEY,
  session_id UUID REFERENCES pqp.pqp_sessions(id) ON DELETE CASCADE,
  ip_address INET,
  asn INTEGER,
  org TEXT,
  country_code TEXT,
  ip_type TEXT,
  reputation_score INT DEFAULT 0,
  risk_reasons JSONB DEFAULT '[]'::jsonb,
  recorded_at TIMESTAMPTZ DEFAULT now()
);

CREATE TABLE IF NOT EXISTS pqp.pqp_leak_tests (
  id BIGSERIAL PRIMARY KEY,
  session_id UUID REFERENCES pqp.pqp_sessions(id) ON DELETE CASCADE,
  test_type TEXT NOT NULL,
  observed_value TEXT,
  expected_value TEXT,
  passed BOOLEAN,
  severity TEXT,
  metadata JSONB DEFAULT '{}'::jsonb,
  recorded_at TIMESTAMPTZ DEFAULT now()
);

CREATE TABLE IF NOT EXISTS pqp.pqp_profile_runs (
  id BIGSERIAL PRIMARY KEY,
  run_id UUID DEFAULT gen_random_uuid(),
  profile_name TEXT,
  provider TEXT,
  proxy_label TEXT,
  client_type TEXT,
  started_at TIMESTAMPTZ DEFAULT now(),
  completed_at TIMESTAMPTZ,
  status TEXT DEFAULT 'started',
  notes TEXT
);

CREATE TABLE IF NOT EXISTS pqp.pqp_capsolver_outcomes (
  id BIGSERIAL PRIMARY KEY,
  session_id UUID REFERENCES pqp.pqp_sessions(id) ON DELETE CASCADE,
  challenge_type TEXT,
  provider TEXT,
  mode TEXT,
  outcome TEXT,
  duration_ms INT,
  cost_usd NUMERIC(10,4),
  error_code TEXT,
  recorded_at TIMESTAMPTZ DEFAULT now()
);

CREATE TABLE IF NOT EXISTS pqp.pqp_fingerprint_uniqueness (
  id BIGSERIAL PRIMARY KEY,
  session_id UUID REFERENCES pqp.pqp_sessions(id) ON DELETE CASCADE,
  canvas_seen_count INT DEFAULT 0,
  audio_seen_count INT DEFAULT 0,
  webgl_seen_count INT DEFAULT 0,
  combined_seen_count INT DEFAULT 0,
  uniqueness_score INT DEFAULT 0,
  fail_reasons JSONB DEFAULT '[]'::jsonb,
  recorded_at TIMESTAMPTZ DEFAULT now()
);

CREATE TABLE IF NOT EXISTS pqp.pqp_session_aging (
  id BIGSERIAL PRIMARY KEY,
  session_id UUID REFERENCES pqp.pqp_sessions(id) ON DELETE CASCADE,
  cookie_present BOOLEAN DEFAULT FALSE,
  local_storage_present BOOLEAN DEFAULT FALSE,
  service_worker_present BOOLEAN DEFAULT FALSE,
  first_seen_at TIMESTAMPTZ,
  last_seen_at TIMESTAMPTZ,
  age_minutes INT DEFAULT 0,
  aging_score INT DEFAULT 0,
  fail_reasons JSONB DEFAULT '[]'::jsonb
);

CREATE TABLE IF NOT EXISTS pqp.pqp_flow_tests (
  id BIGSERIAL PRIMARY KEY,
  session_id UUID REFERENCES pqp.pqp_sessions(id) ON DELETE CASCADE,
  flow_name TEXT,
  flow_step TEXT,
  outcome TEXT,
  duration_ms INT,
  risk_score INT DEFAULT 0,
  metadata JSONB DEFAULT '{}'::jsonb,
  recorded_at TIMESTAMPTZ DEFAULT now()
);

CREATE TABLE IF NOT EXISTS pqp.pqp_evidence_reports (
  id BIGSERIAL PRIMARY KEY,
  session_id UUID REFERENCES pqp.pqp_sessions(id) ON DELETE CASCADE,
  report_path TEXT,
  report_json JSONB,
  created_at TIMESTAMPTZ DEFAULT now()
);
