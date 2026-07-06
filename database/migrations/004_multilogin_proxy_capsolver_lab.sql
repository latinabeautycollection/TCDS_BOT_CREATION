CREATE EXTENSION IF NOT EXISTS pgcrypto;
CREATE SCHEMA IF NOT EXISTS pqp;

CREATE TABLE IF NOT EXISTS pqp.pqp_test_profiles (
  id BIGSERIAL PRIMARY KEY,
  profile_name TEXT NOT NULL,
  provider TEXT DEFAULT 'multilogin',
  proxy_label TEXT,
  proxy_type TEXT,
  expected_country TEXT,
  expected_timezone TEXT,
  user_agent TEXT,
  status TEXT DEFAULT 'active',
  created_at TIMESTAMPTZ DEFAULT now()
);

CREATE TABLE IF NOT EXISTS pqp.pqp_lab_runs (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  run_name TEXT NOT NULL,
  batch_size INT DEFAULT 20,
  total_profiles INT DEFAULT 0,
  status TEXT DEFAULT 'created',
  started_at TIMESTAMPTZ,
  completed_at TIMESTAMPTZ,
  notes TEXT
);

CREATE TABLE IF NOT EXISTS pqp.pqp_lab_run_results (
  id BIGSERIAL PRIMARY KEY,
  run_id UUID REFERENCES pqp.pqp_lab_runs(id) ON DELETE CASCADE,
  session_id UUID REFERENCES pqp.pqp_sessions(id) ON DELETE SET NULL,
  profile_name TEXT,
  proxy_label TEXT,
  reached_home BOOLEAN DEFAULT FALSE,
  reached_login BOOLEAN DEFAULT FALSE,
  reached_product BOOLEAN DEFAULT FALSE,
  reached_cart BOOLEAN DEFAULT FALSE,
  reached_checkout BOOLEAN DEFAULT FALSE,
  challenged BOOLEAN DEFAULT FALSE,
  challenge_outcome TEXT,
  blocked BOOLEAN DEFAULT FALSE,
  redirected BOOLEAN DEFAULT FALSE,
  final_url TEXT,
  total_score INT,
  verdict TEXT,
  error TEXT,
  duration_ms INT,
  created_at TIMESTAMPTZ DEFAULT now()
);
