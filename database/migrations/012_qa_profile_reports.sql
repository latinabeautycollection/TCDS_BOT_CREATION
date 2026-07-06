BEGIN;

CREATE TABLE IF NOT EXISTS pqp.pqp_qa_profile_reports (
  id BIGSERIAL PRIMARY KEY,
  report_run_id UUID NOT NULL,
  session_id UUID,
  profile_name TEXT,
  proxy_label TEXT,
  proxy_ip TEXT,
  proxy_asn TEXT,
  proxy_isp TEXT,
  proxy_type TEXT,
  proxy_country TEXT,
  proxy_region TEXT,
  proxy_city TEXT,
  ip_reputation_score INT,
  ip_risk_reasons JSONB DEFAULT '[]'::jsonb,
  real_capability_score INT,
  phase4_capability_score INT,
  network_score INT,
  fingerprint_score INT,
  behavior_score INT,
  challenge_score INT,
  proxy_score INT,
  population_score INT,
  aging_score INT,
  critical_count INT DEFAULT 0,
  high_count INT DEFAULT 0,
  medium_count INT DEFAULT 0,
  low_count INT DEFAULT 0,
  verdict TEXT,
  top_fail_reasons JSONB DEFAULT '[]'::jsonb,
  source JSONB DEFAULT '{}'::jsonb,
  generated_at TIMESTAMPTZ DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_pqp_qa_reports_run ON pqp.pqp_qa_profile_reports(report_run_id);
CREATE INDEX IF NOT EXISTS idx_pqp_qa_reports_profile ON pqp.pqp_qa_profile_reports(profile_name);
CREATE INDEX IF NOT EXISTS idx_pqp_qa_reports_session ON pqp.pqp_qa_profile_reports(session_id);
CREATE INDEX IF NOT EXISTS idx_pqp_qa_reports_generated ON pqp.pqp_qa_profile_reports(generated_at DESC);
CREATE INDEX IF NOT EXISTS idx_pqp_qa_reports_verdict ON pqp.pqp_qa_profile_reports(verdict);

COMMIT;
