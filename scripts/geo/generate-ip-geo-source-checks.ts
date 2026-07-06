import crypto from "node:crypto";
import { pool } from "../../apps/pqp-api/src/db/pool.js";

const reportRunId = crypto.randomUUID();

async function insertRow(row: any) {
  await pool.query(`
    INSERT INTO pqp.pqp_ip_geo_source_checks (
      report_run_id, profile_name, ip, geo_source,
      asn, isp, country, region, city, timezone, latitude, longitude,
      status, reason, raw
    )
    VALUES ($1,$2,$3,$4,$5,$6,$7,$8,$9,$10,$11,$12,$13,$14,$15::jsonb)
  `, [
    reportRunId,
    row.profile_name,
    row.ip || null,
    row.geo_source,
    row.asn || null,
    row.isp || null,
    row.country || null,
    row.region || null,
    row.city || null,
    row.timezone || null,
    row.latitude ?? null,
    row.longitude ?? null,
    row.status,
    row.reason || null,
    JSON.stringify(row.raw || {})
  ]);
}

async function lookupMaxMind(ip: string) {
  const accountId = process.env.MAXMIND_ACCOUNT_ID;
  const licenseKey = process.env.MAXMIND_LICENSE_KEY;

  if (!accountId || !licenseKey) {
    return { status: "missing_credentials", reason: "MAXMIND_ACCOUNT_ID or MAXMIND_LICENSE_KEY not set" };
  }

  const auth = Buffer.from(`${accountId}:${licenseKey}`).toString("base64");
  const r = await fetch(`https://geoip.maxmind.com/geoip/v2.1/city/${encodeURIComponent(ip)}`, {
    headers: { authorization: `Basic ${auth}` }
  });

  if (!r.ok) {
    return { status: "lookup_failed", reason: `MaxMind HTTP ${r.status}`, raw: { body: await r.text() } };
  }

  const j: any = await r.json();

  return {
    status: "ok",
    asn: j.traits?.autonomous_system_number ? `AS${j.traits.autonomous_system_number}` : null,
    isp: j.traits?.autonomous_system_organization || null,
    country: j.country?.iso_code || null,
    region: j.subdivisions?.[0]?.names?.en || null,
    city: j.city?.names?.en || null,
    timezone: j.location?.time_zone || null,
    latitude: j.location?.latitude ?? null,
    longitude: j.location?.longitude ?? null,
    raw: j
  };
}

async function lookupIp2Location(ip: string) {
  const key = process.env.IP2LOCATION_API_KEY;

  if (!key) {
    return { status: "missing_credentials", reason: "IP2LOCATION_API_KEY not set" };
  }

  const r = await fetch(`https://api.ip2location.io/?key=${encodeURIComponent(key)}&ip=${encodeURIComponent(ip)}&format=json`);

  if (!r.ok) {
    return { status: "lookup_failed", reason: `IP2Location HTTP ${r.status}`, raw: { body: await r.text() } };
  }

  const j: any = await r.json();

  return {
    status: "ok",
    asn: j.asn ? `AS${j.asn}` : null,
    isp: j.as || j.isp || null,
    country: j.country_code || null,
    region: j.region_name || null,
    city: j.city_name || null,
    timezone: j.time_zone || null,
    latitude: j.latitude ?? null,
    longitude: j.longitude ?? null,
    raw: j
  };
}

const latest = await pool.query(`
  SELECT DISTINCT ON (a.profile_name)
    a.profile_name,
    a.proxy_ip,
    a.proxy_asn,
    a.proxy_isp,
    a.proxy_type,
    a.proxy_city,
    a.proxy_region,
    a.proxy_country,
    a.recommended_timezone,
    g.latitude,
    g.longitude
  FROM pqp.pqp_profile_location_alignment a
  LEFT JOIN pqp.pqp_geo_cache g
    ON g.city = a.proxy_city
   AND g.region = a.proxy_region
   AND g.country = a.proxy_country
  WHERE a.profile_name ~ '^ML-US-[0-9]{3}$'
  ORDER BY a.profile_name, a.created_at DESC
`);

for (const r of latest.rows) {
  await insertRow({
    profile_name: r.profile_name,
    ip: r.proxy_ip,
    geo_source: "multilogin_proxy_geo",
    asn: r.proxy_asn,
    isp: r.proxy_isp,
    country: r.proxy_country,
    region: r.proxy_region,
    city: r.proxy_city,
    timezone: r.recommended_timezone,
    latitude: r.latitude,
    longitude: r.longitude,
    status: r.proxy_ip && r.proxy_city && r.proxy_region && r.proxy_country && r.recommended_timezone ? "ok" : "incomplete",
    reason: null,
    raw: r
  });

  if (r.proxy_ip) {
    await insertRow({
      profile_name: r.profile_name,
      ip: r.proxy_ip,
      geo_source: "maxmind",
      ...(await lookupMaxMind(r.proxy_ip))
    });

    await insertRow({
      profile_name: r.profile_name,
      ip: r.proxy_ip,
      geo_source: "ip2location",
      ...(await lookupIp2Location(r.proxy_ip))
    });
  }
}

const summary = await pool.query(`
  SELECT geo_source, status, count(*)::int AS rows
  FROM pqp.pqp_ip_geo_source_checks
  WHERE report_run_id=$1
  GROUP BY geo_source, status
  ORDER BY geo_source, status
`, [reportRunId]);

console.log(JSON.stringify({
  reportRunId,
  profiles: latest.rowCount,
  summary: summary.rows
}, null, 2));

await pool.end();
