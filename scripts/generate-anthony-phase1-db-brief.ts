import { pool } from "../apps/pqp-api/src/db/pool.js";

const reportRunId = crypto.randomUUID();

await pool.query(`
CREATE TABLE IF NOT EXISTS pqp.pqp_phase1_profile_alignment_brief (
  id BIGSERIAL PRIMARY KEY,
  report_run_id UUID NOT NULL,
  profile_name TEXT NOT NULL,
  profile_id TEXT,
  observed_ip TEXT,
  proxy_ip TEXT,
  proxy_asn TEXT,
  proxy_isp TEXT,
  proxy_type TEXT,
  proxy_city TEXT,
  proxy_region TEXT,
  proxy_country TEXT,
  host_emission_status TEXT,
  browser_context_exposed_linode BOOLEAN,
  observed_ip_equals_linode BOOLEAN,
  observed_ip_equals_proxy BOOLEAN,
  proxy_is_datacenter_like BOOLEAN,
  datacenter_emission_detected BOOLEAN,
  current_canvas_noise TEXT,
  target_canvas_noise TEXT,
  current_timezone_masking TEXT,
  current_timezone TEXT,
  target_timezone TEXT,
  current_localization_masking TEXT,
  current_locale TEXT,
  target_locale TEXT,
  current_languages TEXT,
  target_languages TEXT,
  current_geolocation_masking TEXT,
  current_geolocation_latitude NUMERIC,
  current_geolocation_longitude NUMERIC,
  target_geolocation_city TEXT,
  target_geolocation_region TEXT,
  target_geolocation_country TEXT,
  phase4_score INT,
  phase4_verdict TEXT,
  network_score INT,
  fingerprint_score INT,
  behavior_score INT,
  challenge_score INT,
  proxy_score INT,
  population_score INT,
  aging_score INT,
  transaction_score INT,
  population_risk_score INT,
  config_audit_status TEXT,
  action_status TEXT,
  reasons JSONB DEFAULT '[]'::jsonb,
  created_at TIMESTAMPTZ DEFAULT now()
);

CREATE TABLE IF NOT EXISTS pqp.pqp_phase1_reference_profile_gaps (
  id BIGSERIAL PRIMARY KEY,
  report_run_id UUID NOT NULL,
  profile_name TEXT NOT NULL,
  profile_id TEXT,
  phase4_score INT,
  phase4_verdict TEXT,
  network_score INT,
  fingerprint_score INT,
  behavior_score INT,
  challenge_score INT,
  proxy_score INT,
  population_score INT,
  aging_score INT,
  transaction_score INT,
  population_risk_score INT,
  observed_ip TEXT,
  proxy_ip TEXT,
  proxy_isp TEXT,
  proxy_type TEXT,
  proxy_city TEXT,
  proxy_region TEXT,
  proxy_country TEXT,
  host_emission_status TEXT,
  config_audit_status TEXT,
  current_canvas_noise TEXT,
  timezone_zone TEXT,
  locale TEXT,
  languages TEXT,
  geolocation_latitude NUMERIC,
  geolocation_longitude NUMERIC,
  remaining_gaps JSONB DEFAULT '[]'::jsonb,
  created_at TIMESTAMPTZ DEFAULT now()
);
`);

const latest = `
WITH audit AS (
  SELECT DISTINCT ON (profile_name) *
  FROM pqp.pqp_mlx_fingerprint_config_audits
  WHERE profile_name ~ '^ML-US-[0-9]{3}$'
  ORDER BY profile_name, created_at DESC
),
alignment AS (
  SELECT DISTINCT ON (profile_name) *
  FROM pqp.pqp_profile_location_alignment
  WHERE profile_name ~ '^ML-US-[0-9]{3}$'
  ORDER BY profile_name, created_at DESC
),
host AS (
  SELECT DISTINCT ON (profile_name) *
  FROM pqp.pqp_host_emission_checks
  WHERE profile_name ~ '^ML-US-[0-9]{3}$'
  ORDER BY profile_name, created_at DESC
),
phase4 AS (
  SELECT DISTINCT ON (profile_name) *
  FROM pqp.pqp_phase4_score_history
  WHERE profile_name ~ '^ML-US-[0-9]{3}$'
  ORDER BY profile_name, created_at DESC
)
`;

await pool.query(`
${latest}
INSERT INTO pqp.pqp_phase1_profile_alignment_brief (
  report_run_id,
  profile_name,
  profile_id,
  observed_ip,
  proxy_ip,
  proxy_asn,
  proxy_isp,
  proxy_type,
  proxy_city,
  proxy_region,
  proxy_country,
  host_emission_status,
  browser_context_exposed_linode,
  observed_ip_equals_linode,
  observed_ip_equals_proxy,
  proxy_is_datacenter_like,
  datacenter_emission_detected,
  current_canvas_noise,
  target_canvas_noise,
  current_timezone_masking,
  current_timezone,
  target_timezone,
  current_localization_masking,
  current_locale,
  target_locale,
  current_languages,
  target_languages,
  current_geolocation_masking,
  current_geolocation_latitude,
  current_geolocation_longitude,
  target_geolocation_city,
  target_geolocation_region,
  target_geolocation_country,
  phase4_score,
  phase4_verdict,
  network_score,
  fingerprint_score,
  behavior_score,
  challenge_score,
  proxy_score,
  population_score,
  aging_score,
  transaction_score,
  population_risk_score,
  config_audit_status,
  action_status,
  reasons
)
SELECT
  $1,
  a.profile_name,
  a.profile_id,
  al.observed_ip,
  al.proxy_ip,
  al.proxy_asn,
  al.proxy_isp,
  al.proxy_type,
  al.proxy_city,
  al.proxy_region,
  al.proxy_country,
  h.status,
  h.browser_context_exposed_linode,
  h.observed_ip_equals_linode,
  h.observed_ip_equals_proxy,
  h.proxy_is_datacenter_like,
  h.datacenter_emission_detected,
  a.canvas_noise,
  'natural',
  a.timezone_masking,
  a.timezone_zone,
  al.recommended_timezone,
  a.localization_masking,
  a.locale,
  al.recommended_locale,
  a.languages,
  al.recommended_languages,
  a.geolocation_masking,
  a.geolocation_latitude,
  a.geolocation_longitude,
  al.proxy_city,
  al.proxy_region,
  al.proxy_country,
  p.profile_capability_score,
  p.verdict,
  p.network_score,
  p.fingerprint_score,
  p.behavior_score,
  p.challenge_score,
  p.proxy_score,
  p.population_score,
  p.aging_score,
  p.transaction_score,
  p.population_risk_score,
  a.status,
  CASE
    WHEN h.datacenter_emission_detected THEN 'host_emission_review'
    WHEN a.status = 'pass' THEN 'already_aligned'
    ELSE 'needs_profile_config_alignment'
  END,
  a.reasons
FROM audit a
LEFT JOIN alignment al USING (profile_name)
LEFT JOIN host h USING (profile_name)
LEFT JOIN phase4 p USING (profile_name)
ORDER BY a.profile_name
`, [reportRunId]);

const referenceProfiles = await pool.query(`
${latest}
SELECT
  a.profile_name,
  a.profile_id,
  a.canvas_noise,
  a.timezone_zone,
  a.locale,
  a.languages,
  a.geolocation_latitude,
  a.geolocation_longitude,
  a.status AS config_audit_status,
  al.observed_ip,
  al.proxy_ip,
  al.proxy_isp,
  al.proxy_type,
  al.proxy_city,
  al.proxy_region,
  al.proxy_country,
  h.status AS host_emission_status,
  p.profile_capability_score,
  p.verdict,
  p.network_score,
  p.fingerprint_score,
  p.behavior_score,
  p.challenge_score,
  p.proxy_score,
  p.population_score,
  p.aging_score,
  p.transaction_score,
  p.population_risk_score
FROM audit a
LEFT JOIN alignment al USING (profile_name)
LEFT JOIN host h USING (profile_name)
LEFT JOIN phase4 p USING (profile_name)
WHERE a.profile_name IN ('ML-US-001', 'ML-US-007')
ORDER BY a.profile_name
`);

for (const row of referenceProfiles.rows) {
  const gaps: any[] = [];

  if (Number(row.network_score) < 90) {
    gaps.push({
      severity: "medium",
      area: "network",
      reason: "Network score below 90; edge TLS/JA3/JA4 capture is still incomplete until the edge collector is added."
    });
  }

  if (Number(row.fingerprint_score) < 95) {
    gaps.push({
      severity: "medium",
      area: "fingerprint",
      reason: "Fingerprint score below 95; FingerprintJS/CreepJS/deep fingerprint signals need review."
    });
  }

  if (Number(row.behavior_score) < 80) {
    gaps.push({
      severity: "medium",
      area: "behavior",
      reason: "Behavior score below 80; current run does not yet represent long-lived human browsing behavior."
    });
  }

  if (Number(row.aging_score) < 80) {
    gaps.push({
      severity: "medium",
      area: "aging",
      reason: "Aging score below 80; profile storage/history age is still limited."
    });
  }

  if (Number(row.challenge_score) < 90) {
    gaps.push({
      severity: "low",
      area: "challenge",
      reason: "Challenge score below 90; reCAPTCHA/CapSolver signal coverage is not complete."
    });
  }

  await pool.query(`
    INSERT INTO pqp.pqp_phase1_reference_profile_gaps (
      report_run_id,
      profile_name,
      profile_id,
      phase4_score,
      phase4_verdict,
      network_score,
      fingerprint_score,
      behavior_score,
      challenge_score,
      proxy_score,
      population_score,
      aging_score,
      transaction_score,
      population_risk_score,
      observed_ip,
      proxy_ip,
      proxy_isp,
      proxy_type,
      proxy_city,
      proxy_region,
      proxy_country,
      host_emission_status,
      config_audit_status,
      current_canvas_noise,
      timezone_zone,
      locale,
      languages,
      geolocation_latitude,
      geolocation_longitude,
      remaining_gaps
    )
    VALUES (
      $1,$2,$3,$4,$5,$6,$7,$8,$9,$10,
      $11,$12,$13,$14,$15,$16,$17,$18,$19,$20,
      $21,$22,$23,$24,$25,$26,$27,$28,$29,$30
    )
  `, [
    reportRunId,
    row.profile_name,
    row.profile_id,
    row.profile_capability_score,
    row.verdict,
    row.network_score,
    row.fingerprint_score,
    row.behavior_score,
    row.challenge_score,
    row.proxy_score,
    row.population_score,
    row.aging_score,
    row.transaction_score,
    row.population_risk_score,
    row.observed_ip,
    row.proxy_ip,
    row.proxy_isp,
    row.proxy_type,
    row.proxy_city,
    row.proxy_region,
    row.proxy_country,
    row.host_emission_status,
    row.config_audit_status,
    row.canvas_noise,
    row.timezone_zone,
    row.locale,
    row.languages,
    row.geolocation_latitude,
    row.geolocation_longitude,
    JSON.stringify(gaps)
  ]);
}

const summary = await pool.query(`
SELECT
  count(*)::int AS total_profiles,
  count(*) FILTER (WHERE config_audit_status='pass')::int AS already_aligned,
  count(*) FILTER (WHERE action_status='needs_profile_config_alignment')::int AS needs_profile_config_alignment,
  count(*) FILTER (WHERE host_emission_status='pass')::int AS host_emission_pass,
  count(*) FILTER (WHERE datacenter_emission_detected IS TRUE)::int AS datacenter_emission_detected
FROM pqp.pqp_phase1_profile_alignment_brief
WHERE report_run_id=$1
`, [reportRunId]);

const references = await pool.query(`
SELECT profile_name, phase4_score, phase4_verdict, remaining_gaps
FROM pqp.pqp_phase1_reference_profile_gaps
WHERE report_run_id=$1
ORDER BY profile_name
`, [reportRunId]);

console.log(JSON.stringify({
  reportRunId,
  summary: summary.rows[0],
  referenceProfiles: references.rows
}, null, 2));

await pool.end();
