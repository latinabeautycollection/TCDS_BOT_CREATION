BEGIN;

CREATE TABLE IF NOT EXISTS pqp.pqp_deep_fingerprint_scores (
  session_id UUID PRIMARY KEY REFERENCES pqp.pqp_sessions(id) ON DELETE CASCADE,
  profile_name TEXT,
  fingerprintjs_score INT,
  creepjs_score INT,
  population_score INT,
  final_deep_score INT,
  verdict TEXT,
  score_detail JSONB DEFAULT '{}'::jsonb,
  created_at TIMESTAMPTZ DEFAULT now()
);

CREATE TABLE IF NOT EXISTS pqp.pqp_deep_fingerprint_mismatches (
  id BIGSERIAL PRIMARY KEY,
  session_id UUID REFERENCES pqp.pqp_sessions(id) ON DELETE CASCADE,
  profile_name TEXT,
  signal_name TEXT,
  mismatch BOOLEAN DEFAULT false,
  severity TEXT DEFAULT 'low',
  reason TEXT,
  raw JSONB DEFAULT '{}'::jsonb,
  created_at TIMESTAMPTZ DEFAULT now()
);

COMMIT;
