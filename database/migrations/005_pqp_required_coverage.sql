CREATE SCHEMA IF NOT EXISTS pqp;

CREATE TABLE IF NOT EXISTS pqp.pqp_network_proxy_checks (
  id BIGSERIAL PRIMARY KEY,
  session_id UUID REFERENCES pqp.pqp_sessions(id) ON DELETE CASCADE,
  ip_reputation_score INT,
  abuse_history JSONB DEFAULT '[]'::jsonb,
  blocklist_presence BOOLEAN,
  ip_country TEXT,
  ip_city TEXT,
  profile_timezone TEXT,
  profile_language TEXT,
  geo_consistent BOOLEAN,
  asn INTEGER,
  isp_org TEXT,
  isp_type TEXT,
  tcp_os_signature TEXT,
  tcp_profile_match BOOLEAN,
  dns_resolver_ip TEXT,
  dns_resolver_country TEXT,
  dns_leak_detected BOOLEAN,
  recorded_at TIMESTAMPTZ DEFAULT now()
);

CREATE TABLE IF NOT EXISTS pqp.pqp_browser_deep_checks (
  id BIGSERIAL PRIMARY KEY,
  session_id UUID REFERENCES pqp.pqp_sessions(id) ON DELETE CASCADE,
  user_agent TEXT,
  sec_ch_ua TEXT,
  client_hints_consistent BOOLEAN,
  hardware_concurrency INT,
  device_memory INT,
  canvas_hash TEXT,
  webgl_vendor TEXT,
  webgl_renderer TEXT,
  audio_hash TEXT,
  fonts JSONB DEFAULT '[]'::jsonb,
  battery JSONB DEFAULT '{}'::jsonb,
  media_devices JSONB DEFAULT '[]'::jsonb,
  recorded_at TIMESTAMPTZ DEFAULT now()
);

CREATE TABLE IF NOT EXISTS pqp.pqp_execution_checks (
  id BIGSERIAL PRIMARY KEY,
  session_id UUID REFERENCES pqp.pqp_sessions(id) ON DELETE CASCADE,
  webdriver_state TEXT,
  chrome_runtime_present BOOLEAN,
  plugins_count INT,
  chrome_api_consistent BOOLEAN,
  js_pow_duration_ms INT,
  rtt_ms INT,
  behavior_mouse_events INT,
  behavior_key_events INT,
  behavior_scroll_events INT,
  behavior_entropy_score INT,
  recorded_at TIMESTAMPTZ DEFAULT now()
);

CREATE TABLE IF NOT EXISTS pqp.pqp_challenge_deep_checks (
  id BIGSERIAL PRIMARY KEY,
  session_id UUID REFERENCES pqp.pqp_sessions(id) ON DELETE CASCADE,
  provider TEXT,
  challenge_type TEXT,
  token_generated_at TIMESTAMPTZ,
  token_submitted_at TIMESTAMPTZ,
  token_freshness_ms INT,
  solve_time_ms INT,
  fail_count INT DEFAULT 0,
  retry_count INT DEFAULT 0,
  final_outcome TEXT,
  cost_usd NUMERIC(10,4),
  recorded_at TIMESTAMPTZ DEFAULT now()
);

CREATE TABLE IF NOT EXISTS pqp.pqp_coverage_results (
  id BIGSERIAL PRIMARY KEY,
  session_id UUID REFERENCES pqp.pqp_sessions(id) ON DELETE CASCADE,
  network_proxy_coverage INT,
  browser_coverage INT,
  execution_coverage INT,
  challenge_coverage INT,
  total_coverage INT,
  missing_fields JSONB DEFAULT '[]'::jsonb,
  created_at TIMESTAMPTZ DEFAULT now()
);
