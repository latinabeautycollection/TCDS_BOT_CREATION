import { randomUUID } from "crypto";
import { pool } from "../apps/pqp-api/src/db/pool.js";

const base = process.env.PQP_DIRECT_BASE_URL || "http://127.0.0.1:8088";

type AnyObj = Record<string, any>;

function norm(v: any) {
  return v === undefined ? null : v;
}

function same(a: any, b: any) {
  return String(a || "").trim() !== "" && String(a || "").trim() === String(b || "").trim();
}

function isDatacenterLike(proxy: AnyObj, linode: AnyObj) {
  const type = String(proxy?.type || "").toLowerCase();
  const isp = String(proxy?.isp || "").toLowerCase();
  const asn = String(proxy?.asn || "").toLowerCase();
  const linodeAsn = String(linode?.asn || "").toLowerCase();

  if (same(asn, linodeAsn)) return true;
  if (["hosting", "datacenter", "vpn", "proxy", "tor"].includes(type)) return true;
  if (isp.includes("linode") || isp.includes("akamai cloud") || isp.includes("digitalocean")) return true;
  if (isp.includes("amazon") || isp.includes("aws") || isp.includes("google cloud")) return true;
  if (isp.includes("microsoft") || isp.includes("azure") || isp.includes("ovh")) return true;

  return false;
}

async function getJson(path: string, headers: Record<string, string> = {}) {
  const res = await fetch(`${base}${path}`, { headers });
  const text = await res.text();

  if (!res.ok) {
    return { ok: false, status: res.status, body: text };
  }

  try {
    return JSON.parse(text);
  } catch {
    return { ok: false, status: res.status, body: text };
  }
}

async function ensureTable() {
  await pool.query(`
    CREATE TABLE IF NOT EXISTS pqp.pqp_host_emission_checks (
      id BIGSERIAL PRIMARY KEY,
      report_run_id UUID NOT NULL,
      session_id UUID NOT NULL,
      profile_name TEXT,
      observed_browser_ip TEXT,
      linode_ip TEXT,
      linode_asn TEXT,
      linode_city TEXT,
      linode_region TEXT,
      linode_country TEXT,
      proxy_ip TEXT,
      proxy_asn TEXT,
      proxy_isp TEXT,
      proxy_type TEXT,
      proxy_city TEXT,
      proxy_region TEXT,
      proxy_country TEXT,
      browser_context_exposed_linode BOOLEAN NOT NULL DEFAULT false,
      observed_ip_equals_linode BOOLEAN NOT NULL DEFAULT false,
      observed_ip_equals_proxy BOOLEAN NOT NULL DEFAULT false,
      proxy_is_datacenter_like BOOLEAN NOT NULL DEFAULT false,
      datacenter_emission_detected BOOLEAN NOT NULL DEFAULT false,
      status TEXT NOT NULL,
      reasons JSONB NOT NULL DEFAULT '[]'::jsonb,
      browser_context JSONB NOT NULL DEFAULT '{}'::jsonb,
      internal_context JSONB NOT NULL DEFAULT '{}'::jsonb,
      created_at TIMESTAMPTZ NOT NULL DEFAULT now()
    );

    CREATE INDEX IF NOT EXISTS idx_pqp_host_emission_report
      ON pqp.pqp_host_emission_checks(report_run_id);

    CREATE INDEX IF NOT EXISTS idx_pqp_host_emission_session
      ON pqp.pqp_host_emission_checks(session_id);

    CREATE INDEX IF NOT EXISTS idx_pqp_host_emission_profile
      ON pqp.pqp_host_emission_checks(profile_name);

    CREATE INDEX IF NOT EXISTS idx_pqp_host_emission_created
      ON pqp.pqp_host_emission_checks(created_at DESC);
  `);
}

async function main() {
  await ensureTable();

  const reportRunId = randomUUID();

  const sessions = await pool.query(`
    SELECT DISTINCT ON (profile_name)
      id::text AS session_id,
      profile_name,
      host(ip_address) AS observed_browser_ip,
      started_at
    FROM pqp.pqp_sessions
    WHERE profile_name ~ '^ML-US-[0-9]{3}$'
      AND ip_address IS NOT NULL
      AND NOT ip_address <<= inet '127.0.0.0/8'
    ORDER BY profile_name, started_at DESC
  `);

  const rows = [];

  for (const s of sessions.rows) {
    const browserContext = await getJson(`/api/pqp/session-context/${s.session_id}`);
    const internalContext = await getJson(`/api/pqp/session-context/${s.session_id}`, {
      "x-pqp-internal-report": "1"
    });

    const linode = internalContext?.linode || {};
    const proxy = browserContext?.proxy || internalContext?.proxy || {};

    const reasons: AnyObj[] = [];

    const browserContextExposedLinode = Boolean(browserContext?.linode);
    const observedIpEqualsLinode = same(s.observed_browser_ip, linode.ip);
    const observedIpEqualsProxy = same(s.observed_browser_ip, proxy.ip);
    const proxyIsDatacenterLike = isDatacenterLike(proxy, linode);

    if (browserContextExposedLinode) {
      reasons.push({
        severity: "critical",
        reason: "Browser-facing session-context exposed Linode/server identity"
      });
    }

    if (observedIpEqualsLinode) {
      reasons.push({
        severity: "critical",
        reason: "Observed browser IP equals Linode/server IP"
      });
    }

    if (!observedIpEqualsProxy) {
      reasons.push({
        severity: "high",
        reason: "Observed browser IP does not match residential proxy IP",
        observedBrowserIp: s.observed_browser_ip,
        proxyIp: proxy.ip || null
      });
    }

    if (proxyIsDatacenterLike) {
      reasons.push({
        severity: "high",
        reason: "Proxy identity appears datacenter-like or matches host ASN",
        proxyType: proxy.type || null,
        proxyIsp: proxy.isp || null,
        proxyAsn: proxy.asn || null
      });
    }

    if (!proxy.ip || !proxy.asn || !proxy.type) {
      reasons.push({
        severity: "medium",
        reason: "Proxy identity is incomplete in session context"
      });
    }

    const datacenterEmissionDetected =
      browserContextExposedLinode || observedIpEqualsLinode || proxyIsDatacenterLike;

    const status = datacenterEmissionDetected
      ? "fail"
      : reasons.some(r => r.severity === "high")
        ? "warning"
        : "pass";

    await pool.query(
      `INSERT INTO pqp.pqp_host_emission_checks (
        report_run_id, session_id, profile_name, observed_browser_ip,
        linode_ip, linode_asn, linode_city, linode_region, linode_country,
        proxy_ip, proxy_asn, proxy_isp, proxy_type, proxy_city, proxy_region, proxy_country,
        browser_context_exposed_linode, observed_ip_equals_linode, observed_ip_equals_proxy,
        proxy_is_datacenter_like, datacenter_emission_detected, status, reasons,
        browser_context, internal_context
      ) VALUES (
        $1,$2,$3,$4,$5,$6,$7,$8,$9,$10,$11,$12,$13,$14,$15,$16,
        $17,$18,$19,$20,$21,$22,$23,$24,$25
      )`,
      [
        reportRunId,
        s.session_id,
        s.profile_name,
        s.observed_browser_ip,
        norm(linode.ip),
        norm(linode.asn),
        norm(linode.city),
        norm(linode.region),
        norm(linode.country),
        norm(proxy.ip),
        norm(proxy.asn),
        norm(proxy.isp),
        norm(proxy.type),
        norm(proxy.city),
        norm(proxy.region),
        norm(proxy.country),
        browserContextExposedLinode,
        observedIpEqualsLinode,
        observedIpEqualsProxy,
        proxyIsDatacenterLike,
        datacenterEmissionDetected,
        status,
        JSON.stringify(reasons),
        JSON.stringify(browserContext || {}),
        JSON.stringify(internalContext || {})
      ]
    );

    rows.push({
      profileName: s.profile_name,
      sessionId: s.session_id,
      observedBrowserIp: s.observed_browser_ip,
      linode,
      proxy,
      browserContextExposedLinode,
      observedIpEqualsLinode,
      observedIpEqualsProxy,
      proxyIsDatacenterLike,
      datacenterEmissionDetected,
      status,
      reasons
    });
  }

  const summary = {
    reportRunId,
    totalRows: rows.length,
    pass: rows.filter(r => r.status === "pass").length,
    warning: rows.filter(r => r.status === "warning").length,
    fail: rows.filter(r => r.status === "fail").length,
    generatedAt: new Date().toISOString()
  };

  console.log(JSON.stringify({ summary, rows }, null, 2));

  await pool.end();
}

main().catch(err => {
  console.error(err);
  process.exit(1);
});
