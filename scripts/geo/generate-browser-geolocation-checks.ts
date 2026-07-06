import crypto from "node:crypto";
import { pool } from "../../apps/pqp-api/src/db/pool.js";

const reportRunId = crypto.randomUUID();

function toRad(n: number) {
  return n * Math.PI / 180;
}

function distanceKm(lat1: number, lon1: number, lat2: number, lon2: number) {
  const r = 6371;
  const dLat = toRad(lat2 - lat1);
  const dLon = toRad(lon2 - lon1);
  const a =
    Math.sin(dLat / 2) ** 2 +
    Math.cos(toRad(lat1)) * Math.cos(toRad(lat2)) *
    Math.sin(dLon / 2) ** 2;
  return 2 * r * Math.asin(Math.sqrt(a));
}

function numberOrNull(v: any) {
  const n = Number(v);
  return Number.isFinite(n) ? n : null;
}

const q = await pool.query(`
  WITH latest_snap AS (
    SELECT DISTINCT ON (profile_name)
      session_id,
      profile_name,
      snapshot,
      created_at
    FROM pqp.pqp_real_capability_snapshots
    WHERE profile_name ~ '^ML-US-[0-9]{3}$'
    ORDER BY profile_name, created_at DESC
  ),
  latest_align AS (
    SELECT DISTINCT ON (profile_name)
      profile_name,
      proxy_city,
      proxy_region,
      proxy_country
    FROM pqp.pqp_profile_location_alignment
    WHERE profile_name ~ '^ML-US-[0-9]{3}$'
    ORDER BY profile_name, created_at DESC
  )
  SELECT
    s.session_id,
    s.profile_name,
    s.snapshot,
    a.proxy_city,
    a.proxy_region,
    a.proxy_country,
    g.latitude AS proxy_latitude,
    g.longitude AS proxy_longitude
  FROM latest_snap s
  LEFT JOIN latest_align a USING (profile_name)
  LEFT JOIN pqp.pqp_geo_cache g
    ON g.city = a.proxy_city
   AND g.region = a.proxy_region
   AND g.country = a.proxy_country
  ORDER BY s.profile_name
`);

for (const row of q.rows) {
  const snap = row.snapshot || {};
  const geo =
    snap.geolocation ||
    snap.browserGeolocation ||
    snap.extraBrowserSignals?.geolocation ||
    snap.navigator?.geolocation ||
    {};

  const browserLatitude = numberOrNull(geo.latitude ?? geo.lat);
  const browserLongitude = numberOrNull(geo.longitude ?? geo.lon ?? geo.lng);
  const browserAccuracy = numberOrNull(geo.accuracy);

  const browserGeoStatus =
    geo.status ||
    (geo.ok === true ? "ok" : null) ||
    (browserLatitude != null && browserLongitude != null ? "ok" : "missing");

  const reasons: any[] = [];
  let status = "pass";
  let dist: number | null = null;

  if (browserGeoStatus !== "ok") {
    status = "warning";
    reasons.push({ severity: "medium", reason: "Browser geolocation missing or unavailable" });
  }

  if (browserLatitude == null || browserLongitude == null) {
    status = "warning";
    reasons.push({ severity: "medium", reason: "Browser geolocation latitude/longitude missing" });
  }

  if (row.proxy_latitude == null || row.proxy_longitude == null) {
    status = "warning";
    reasons.push({ severity: "medium", reason: "Proxy geo cache latitude/longitude missing" });
  }

  if (
    browserLatitude != null &&
    browserLongitude != null &&
    row.proxy_latitude != null &&
    row.proxy_longitude != null
  ) {
    dist = distanceKm(browserLatitude, browserLongitude, Number(row.proxy_latitude), Number(row.proxy_longitude));

    if (dist > 100) {
      status = "fail";
      reasons.push({ severity: "high", reason: `Browser geolocation is ${Math.round(dist)}km from proxy geo cache` });
    } else if (dist > 50) {
      status = status === "fail" ? status : "warning";
      reasons.push({ severity: "medium", reason: `Browser geolocation is ${Math.round(dist)}km from proxy geo cache` });
    }
  }

  await pool.query(`
    INSERT INTO pqp.pqp_browser_geolocation_checks (
      report_run_id, session_id, profile_name,
      browser_latitude, browser_longitude, browser_accuracy,
      browser_geo_status, browser_geo_error_code, browser_geo_error_message,
      proxy_city, proxy_region, proxy_country,
      proxy_latitude, proxy_longitude,
      distance_km, status, reasons, raw
    )
    VALUES (
      $1,$2,$3,$4,$5,$6,$7,$8,$9,$10,$11,$12,$13,$14,$15,$16,$17::jsonb,$18::jsonb
    )
  `, [
    reportRunId,
    row.session_id,
    row.profile_name,
    browserLatitude,
    browserLongitude,
    browserAccuracy,
    browserGeoStatus,
    geo.code ?? null,
    geo.message ?? geo.error ?? null,
    row.proxy_city,
    row.proxy_region,
    row.proxy_country,
    row.proxy_latitude,
    row.proxy_longitude,
    dist,
    status,
    JSON.stringify(reasons),
    JSON.stringify({ geolocation: geo, snapshotCreatedAt: row.created_at })
  ]);
}

const summary = await pool.query(`
  SELECT status, browser_geo_status, count(*)::int AS rows
  FROM pqp.pqp_browser_geolocation_checks
  WHERE report_run_id=$1
  GROUP BY status, browser_geo_status
  ORDER BY status, browser_geo_status
`, [reportRunId]);

console.log(JSON.stringify({
  reportRunId,
  profiles: q.rowCount,
  summary: summary.rows
}, null, 2));

await pool.end();
