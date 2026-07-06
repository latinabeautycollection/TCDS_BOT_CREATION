CREATE EXTENSION IF NOT EXISTS pgcrypto;
CREATE SCHEMA IF NOT EXISTS pqp;

CREATE TABLE IF NOT EXISTS pqp.pqp_sessions (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  started_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  completed_at TIMESTAMPTZ,
  profile_name TEXT,
  client_type TEXT,
  ip_address INET,
  user_agent TEXT,
  country_code TEXT,
  region TEXT,
  city TEXT,
  total_score INT,
  verdict TEXT
);

CREATE TABLE IF NOT EXISTS pqp.pqp_edge_events (
  id BIGSERIAL PRIMARY KEY,
  session_id UUID REFERENCES pqp.pqp_sessions(id) ON DELETE CASCADE,
  recorded_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  ip_address INET,
  forwarded_for TEXT,
  http_version TEXT,
  tls_version TEXT,
  alpn TEXT,
  ja3_hash TEXT,
  ja4_hash TEXT,
  header_names TEXT[],
  header_consistency_score INT DEFAULT 0,
  leak_detected BOOLEAN DEFAULT FALSE
);

CREATE TABLE IF NOT EXISTS pqp.pqp_browser_fingerprints (
  id BIGSERIAL PRIMARY KEY,
  session_id UUID REFERENCES pqp.pqp_sessions(id) ON DELETE CASCADE,
  recorded_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  user_agent TEXT,
  languages TEXT[],
  platform TEXT,
  timezone TEXT,
  screen_width INT,
  screen_height INT,
  color_depth INT,
  cpu_cores INT,
  device_memory INT,
  webdriver_flag BOOLEAN,
  canvas_hash TEXT,
  audio_hash TEXT,
  webgl_vendor TEXT,
  webgl_renderer TEXT,
  plugin_count INT,
  raw JSONB
);

CREATE TABLE IF NOT EXISTS pqp.pqp_behavior_events (
  id BIGSERIAL PRIMARY KEY,
  session_id UUID REFERENCES pqp.pqp_sessions(id) ON DELETE CASCADE,
  event_time TIMESTAMPTZ NOT NULL DEFAULT now(),
  event_type TEXT NOT NULL,
  x_position INT,
  y_position INT,
  target_element TEXT,
  metadata JSONB DEFAULT '{}'::jsonb
);

CREATE TABLE IF NOT EXISTS pqp.pqp_challenge_events (
  id BIGSERIAL PRIMARY KEY,
  session_id UUID REFERENCES pqp.pqp_sessions(id) ON DELETE CASCADE,
  challenge_type TEXT,
  issued_at TIMESTAMPTZ DEFAULT now(),
  completed_at TIMESTAMPTZ,
  outcome TEXT,
  duration_ms INT
);

CREATE TABLE IF NOT EXISTS pqp.pqp_scores (
  session_id UUID PRIMARY KEY REFERENCES pqp.pqp_sessions(id) ON DELETE CASCADE,
  network_score INT NOT NULL,
  browser_score INT NOT NULL,
  behavior_score INT NOT NULL,
  continuity_score INT NOT NULL,
  challenge_score INT NOT NULL,
  total_score INT NOT NULL,
  verdict TEXT NOT NULL,
  fail_reasons JSONB NOT NULL DEFAULT '[]'::jsonb,
  scored_at TIMESTAMPTZ NOT NULL DEFAULT now()
);
