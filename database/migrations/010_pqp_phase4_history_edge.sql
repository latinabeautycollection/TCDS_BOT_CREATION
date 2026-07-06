BEGIN;

CREATE TABLE IF NOT EXISTS pqp.pqp_phase4_score_history (
  id BIGSERIAL PRIMARY KEY,
  session_id UUID REFERENCES pqp.pqp_sessions(id) ON DELETE CASCADE,
  profile_name TEXT,
  network_score INT,
  fingerprint_score INT,
  behavior_score INT,
  challenge_score INT,
  proxy_score INT,
  population_score INT,
  aging_score INT,
  profile_capability_score INT,
  verdict TEXT,
  score_detail JSONB DEFAULT '{}'::jsonb,
  created_at TIMESTAMPTZ DEFAULT now()
);

CREATE TABLE IF NOT EXISTS pqp.pqp_edge_fingerprint_events (
  id BIGSERIAL PRIMARY KEY,
  session_id UUID REFERENCES pqp.pqp_sessions(id) ON DELETE CASCADE,
  profile_name TEXT,
  ip TEXT,
  ja3 TEXT,
  ja4 TEXT,
  tls_version TEXT,
  alpn TEXT,
  http_version TEXT,
  header_order JSONB DEFAULT '[]'::jsonb,
  raw JSONB DEFAULT '{}'::jsonb,
  created_at TIMESTAMPTZ DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_pqp_phase4_history_session ON pqp.pqp_phase4_score_history(session_id);
CREATE INDEX IF NOT EXISTS idx_pqp_phase4_history_profile ON pqp.pqp_phase4_score_history(profile_name);
CREATE INDEX IF NOT EXISTS idx_pqp_phase4_history_score ON pqp.pqp_phase4_score_history(profile_capability_score DESC);
CREATE INDEX IF NOT EXISTS idx_pqp_phase4_history_created ON pqp.pqp_phase4_score_history(created_at DESC);

CREATE INDEX IF NOT EXISTS idx_pqp_edge_fp_session ON pqp.pqp_edge_fingerprint_events(session_id);
CREATE INDEX IF NOT EXISTS idx_pqp_edge_fp_profile ON pqp.pqp_edge_fingerprint_events(profile_name);
CREATE INDEX IF NOT EXISTS idx_pqp_edge_fp_ja3 ON pqp.pqp_edge_fingerprint_events(ja3);
CREATE INDEX IF NOT EXISTS idx_pqp_edge_fp_ja4 ON pqp.pqp_edge_fingerprint_events(ja4);
CREATE INDEX IF NOT EXISTS idx_pqp_edge_fp_created ON pqp.pqp_edge_fingerprint_events(created_at DESC);

COMMIT;
