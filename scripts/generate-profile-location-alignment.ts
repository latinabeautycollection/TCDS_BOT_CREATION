import { pool } from "../apps/pqp-api/src/db/pool.js";

const reportRunId = crypto.randomUUID();

await pool.query(`
CREATE TABLE IF NOT EXISTS pqp.pqp_profile_location_alignment (
  id BIGSERIAL PRIMARY KEY,
  report_run_id UUID NOT NULL,
  profile_name TEXT NOT NULL,
  session_id UUID,
  observed_ip TEXT,
  proxy_ip TEXT,
  proxy_asn TEXT,
  proxy_isp TEXT,
  proxy_type TEXT,
  proxy_city TEXT,
  proxy_region TEXT,
  proxy_country TEXT,
  recommended_timezone TEXT,
  recommended_locale TEXT,
  recommended_languages TEXT,
  status TEXT,
  reasons JSONB DEFAULT '[]'::jsonb,
  created_at TIMESTAMPTZ DEFAULT now()
);
`);

const sessions = await pool.query(`
  SELECT DISTINCT ON (profile_name)
    id, profile_name, host(ip_address) AS observed_ip
  FROM pqp.pqp_sessions
  WHERE profile_name ~ '^ML-US-[0-9]{3}$'
    AND ip_address IS NOT NULL
    AND NOT ip_address <<= inet '127.0.0.0/8'
  ORDER BY profile_name, started_at DESC
`);

for (const s of sessions.rows) {
  const ctxRes = await fetch(`http://127.0.0.1:8088/api/pqp/session-context/${s.id}`, {
    headers: { "x-pqp-internal-report": "1" }
  });

  const ctx = ctxRes.ok ? await ctxRes.json() : {};
  const proxy = ctx.proxy || {};
  const reasons: any[] = [];

  let status = "ready_to_lock";

  if (!proxy.ip) {
    status = "missing_proxy";
    reasons.push({ severity: "high", reason: "No proxy IP emitted" });
  }

  if (!proxy.city || !proxy.region || !proxy.country) {
    status = "needs_location_lookup";
    reasons.push({ severity: "medium", reason: "Proxy location incomplete" });
  }

  const timezoneKey = [
    proxy.city || "",
    proxy.region || "",
    proxy.country || ""
  ].join("|").toLowerCase();

  const timezoneOverrides: Record<string, string> = {
    "whiteville|north carolina|us": "America/New_York",
    "pensacola|florida|us": "America/Chicago",
    "phoenix|arizona|us": "America/Phoenix"
  };

  const timezone =
    timezoneOverrides[timezoneKey] ||
    (proxy.region === "Illinois" ? "America/Chicago" :
    proxy.region === "Texas" ? "America/Chicago" :
    proxy.region === "New York" ? "America/New_York" :
    proxy.region === "North Carolina" ? "America/New_York" :
    proxy.region === "Arizona" ? "America/Phoenix" :
    proxy.region === "California" ? "America/Los_Angeles" :
    null);

  await pool.query(`
    INSERT INTO pqp.pqp_profile_location_alignment (
      report_run_id, profile_name, session_id, observed_ip,
      proxy_ip, proxy_asn, proxy_isp, proxy_type, proxy_city, proxy_region, proxy_country,
      recommended_timezone, recommended_locale, recommended_languages,
      status, reasons
    )
    VALUES ($1,$2,$3,$4,$5,$6,$7,$8,$9,$10,$11,$12,$13,$14,$15,$16)
  `, [
    reportRunId,
    s.profile_name,
    s.id,
    s.observed_ip,
    proxy.ip || null,
    proxy.asn || null,
    proxy.isp || null,
    proxy.type || null,
    proxy.city || null,
    proxy.region || null,
    proxy.country || null,
    timezone,
    "en-US",
    "en-US,en",
    status,
    JSON.stringify(reasons)
  ]);
}

const out = await pool.query(`
  SELECT profile_name, observed_ip, proxy_ip, proxy_isp, proxy_type,
         proxy_city, proxy_region, proxy_country,
         recommended_timezone, recommended_locale, recommended_languages,
         status, reasons
  FROM pqp.pqp_profile_location_alignment
  WHERE report_run_id=$1
  ORDER BY profile_name
`, [reportRunId]);

console.log(JSON.stringify({
  reportRunId,
  totalRows: out.rowCount,
  rows: out.rows
}, null, 2));

await pool.end();
