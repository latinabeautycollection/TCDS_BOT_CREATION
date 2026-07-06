CREATE EXTENSION IF NOT EXISTS pgcrypto;
CREATE SCHEMA IF NOT EXISTS pqp;

CREATE TABLE IF NOT EXISTS pqp.pqp_edge_log_ingest (
  id BIGSERIAL PRIMARY KEY,
  session_id UUID REFERENCES pqp.pqp_sessions(id) ON DELETE CASCADE,
  source TEXT NOT NULL,
  request_id TEXT,
  ip_address INET,
  ja3_hash TEXT,
  ja4_hash TEXT,
  tls_version TEXT,
  alpn TEXT,
  http_version TEXT,
  header_order TEXT[],
  raw JSONB DEFAULT '{}'::jsonb,
  recorded_at TIMESTAMPTZ DEFAULT now()
);

CREATE TABLE IF NOT EXISTS pqp.pqp_alerts (
  id BIGSERIAL PRIMARY KEY,
  session_id UUID REFERENCES pqp.pqp_sessions(id) ON DELETE CASCADE,
  alert_type TEXT,
  severity TEXT,
  message TEXT,
  destination TEXT,
  delivered BOOLEAN DEFAULT FALSE,
  created_at TIMESTAMPTZ DEFAULT now()
);

CREATE TABLE IF NOT EXISTS pqp.pqp_baseline_runs (
  id BIGSERIAL PRIMARY KEY,
  baseline_type TEXT NOT NULL,
  label TEXT NOT NULL,
  session_id UUID REFERENCES pqp.pqp_sessions(id) ON DELETE SET NULL,
  total_score INT,
  network_score INT,
  browser_score INT,
  behavior_score INT,
  continuity_score INT,
  challenge_score INT,
  verdict TEXT,
  created_at TIMESTAMPTZ DEFAULT now()
);

CREATE OR REPLACE VIEW pqp.pqp_longitudinal_summary AS
SELECT
  baseline_type,
  count(*)::int AS run_count,
  round(avg(total_score),2) AS avg_total_score,
  max(total_score)::int AS max_total_score,
  min(total_score)::int AS min_total_score
FROM pqp.pqp_baseline_runs
GROUP BY baseline_type;
