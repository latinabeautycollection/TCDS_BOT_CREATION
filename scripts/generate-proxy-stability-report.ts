import { randomUUID } from "crypto";
import { pool } from "../apps/pqp-api/src/db/pool.js";

async function ensureTable() {
  await pool.query(`
    CREATE TABLE IF NOT EXISTS pqp.pqp_proxy_stability_reports (
      id BIGSERIAL PRIMARY KEY,
      report_run_id UUID NOT NULL,
      profile_name TEXT NOT NULL,
      observed_proxy_count INT NOT NULL,
      latest_proxy_ip TEXT,
      latest_proxy_asn TEXT,
      latest_proxy_isp TEXT,
      latest_proxy_type TEXT,
      latest_proxy_city TEXT,
      latest_proxy_region TEXT,
      latest_proxy_country TEXT,
      proxy_changed BOOLEAN NOT NULL DEFAULT false,
      status TEXT NOT NULL,
      reasons JSONB NOT NULL DEFAULT '[]'::jsonb,
      observed_proxies JSONB NOT NULL DEFAULT '[]'::jsonb,
      created_at TIMESTAMPTZ NOT NULL DEFAULT now()
    );

    CREATE INDEX IF NOT EXISTS idx_pqp_proxy_stability_profile
      ON pqp.pqp_proxy_stability_reports(profile_name);

    CREATE INDEX IF NOT EXISTS idx_pqp_proxy_stability_run
      ON pqp.pqp_proxy_stability_reports(report_run_id);

    CREATE INDEX IF NOT EXISTS idx_pqp_proxy_stability_created
      ON pqp.pqp_proxy_stability_reports(created_at DESC);
  `);
}

async function main() {
  await ensureTable();

  const reportRunId = randomUUID();

  const profiles = await pool.query(`
    SELECT profile_name
    FROM pqp.pqp_sessions
    WHERE profile_name ~ '^ML-US-[0-9]{3}$'
      AND ip_address IS NOT NULL
      AND NOT ip_address <<= inet '127.0.0.0/8'
    GROUP BY profile_name
    ORDER BY profile_name
  `);

  const rows = [];

  for (const p of profiles.rows) {
    const q = await pool.query(`
      SELECT
        s.id::text AS session_id,
        host(s.ip_address) AS proxy_ip,
        ir.asn AS proxy_asn,
        ir.org AS proxy_isp,
        ir.ip_type AS proxy_type,
        ir.country_code AS proxy_country,
        ir.city AS proxy_city,
        ir.region AS proxy_region,
        s.started_at
      FROM pqp.pqp_sessions s
      LEFT JOIN pqp.pqp_ip_reputation ir ON ir.session_id = s.id
      WHERE s.profile_name=$1
        AND s.ip_address IS NOT NULL
        AND NOT s.ip_address <<= inet '127.0.0.0/8'
      ORDER BY s.started_at DESC
    `, [p.profile_name]);

    const observed = q.rows;
    const latest = observed[0] || {};
    const uniqueProxyIps = new Set(observed.map(r => r.proxy_ip).filter(Boolean));
    const proxyChanged = uniqueProxyIps.size > 1;

    const reasons = [];

    if (observed.length === 0) {
      reasons.push({ severity: "medium", reason: "No observed residential proxy sessions found" });
    }

    if (proxyChanged) {
      reasons.push({
        severity: "high",
        reason: "Profile has used more than one observed proxy IP",
        proxyIps: [...uniqueProxyIps]
      });
    }

    if (latest.proxy_type && String(latest.proxy_type).toLowerCase() !== "residential") {
      reasons.push({
        severity: "high",
        reason: "Latest proxy type is not residential",
        proxyType: latest.proxy_type
      });
    }

    if (!latest.proxy_asn || !latest.proxy_isp || !latest.proxy_country) {
      reasons.push({
        severity: "medium",
        reason: "Latest proxy intelligence is incomplete"
      });
    }

    const status = reasons.some(r => r.severity === "high")
      ? "warning"
      : "pass";

    await pool.query(`
      INSERT INTO pqp.pqp_proxy_stability_reports (
        report_run_id, profile_name, observed_proxy_count,
        latest_proxy_ip, latest_proxy_asn, latest_proxy_isp, latest_proxy_type,
        latest_proxy_city, latest_proxy_region, latest_proxy_country,
        proxy_changed, status, reasons, observed_proxies
      ) VALUES ($1,$2,$3,$4,$5,$6,$7,$8,$9,$10,$11,$12,$13,$14)
    `, [
      reportRunId,
      p.profile_name,
      uniqueProxyIps.size,
      latest.proxy_ip || null,
      latest.proxy_asn || null,
      latest.proxy_isp || null,
      latest.proxy_type || null,
      latest.proxy_city || null,
      latest.proxy_region || null,
      latest.proxy_country || null,
      proxyChanged,
      status,
      JSON.stringify(reasons),
      JSON.stringify(observed.slice(0, 20))
    ]);

    rows.push({
      profileName: p.profile_name,
      observedProxyCount: uniqueProxyIps.size,
      latestProxyIp: latest.proxy_ip || null,
      latestProxyAsn: latest.proxy_asn || null,
      latestProxyIsp: latest.proxy_isp || null,
      latestProxyType: latest.proxy_type || null,
      latestProxyCity: latest.proxy_city || null,
      latestProxyRegion: latest.proxy_region || null,
      latestProxyCountry: latest.proxy_country || null,
      proxyChanged,
      status,
      reasons
    });
  }

  console.log(JSON.stringify({
    reportRunId,
    totalRows: rows.length,
    pass: rows.filter(r => r.status === "pass").length,
    warning: rows.filter(r => r.status === "warning").length,
    rows
  }, null, 2));

  await pool.end();
}

main().catch(err => {
  console.error(err);
  process.exit(1);
});
