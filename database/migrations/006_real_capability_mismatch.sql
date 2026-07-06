CREATE TABLE IF NOT EXISTS pqp.pqp_real_capability_snapshots (
  id BIGSERIAL PRIMARY KEY,
  session_id UUID REFERENCES pqp.pqp_sessions(id) ON DELETE CASCADE,
  profile_name TEXT,
  proxy_label TEXT,
  snapshot JSONB NOT NULL,
  created_at TIMESTAMPTZ DEFAULT now()
);

CREATE TABLE IF NOT EXISTS pqp.pqp_mismatch_results (
  id BIGSERIAL PRIMARY KEY,
  session_id UUID REFERENCES pqp.pqp_sessions(id) ON DELETE CASCADE,
  profile_name TEXT,
  proxy_label TEXT,
  signal_group TEXT NOT NULL,
  signal_name TEXT NOT NULL,
  linode_value TEXT,
  proxy_value TEXT,
  browser_value TEXT,
  expected_value TEXT,
  mismatch BOOLEAN DEFAULT FALSE,
  severity TEXT DEFAULT 'low',
  reason TEXT,
  created_at TIMESTAMPTZ DEFAULT now()
);

CREATE TABLE IF NOT EXISTS pqp.pqp_real_capability_scores (
  session_id UUID PRIMARY KEY REFERENCES pqp.pqp_sessions(id) ON DELETE CASCADE,
  profile_name TEXT,
  proxy_label TEXT,
  browser_attribute_score INT,
  navigator_score INT,
  timezone_locale_score INT,
  geolocation_score INT,
  media_device_score INT,
  graphics_score INT,
  fonts_screen_score INT,
  webrtc_score INT,
  network_protocol_score INT,
  ports_score INT,
  session_stability_score INT,
  challenge_score INT,
  final_capability_score INT,
  critical_count INT,
  high_count INT,
  medium_count INT,
  low_count INT,
  verdict TEXT,
  created_at TIMESTAMPTZ DEFAULT now()
);
