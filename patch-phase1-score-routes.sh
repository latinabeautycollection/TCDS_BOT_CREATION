#!/usr/bin/env bash
set -euo pipefail

mkdir -p database/migrations backups/phase1-score

cp apps/pqp-api/src/phase4/pqpPhase4Routes.ts "backups/phase1-score/pqpPhase4Routes.ts.$(date +%s).bak"
cp apps/pqp-api/src/phase4/pqpPhase4CapabilityEngine.ts "backups/phase1-score/pqpPhase4CapabilityEngine.ts.$(date +%s).bak"

cat > database/migrations/014_phase1_edge_transaction_aging.sql <<'SQL'
CREATE TABLE IF NOT EXISTS pqp.pqp_edge_http_events (
  id BIGSERIAL PRIMARY KEY,
  session_id UUID,
  profile_name TEXT,
  ip INET,
  ja3 TEXT,
  ja4 TEXT,
  tls_version TEXT,
  cipher_suite TEXT,
  sni TEXT,
  alpn TEXT,
  http_version TEXT,
  h2_settings JSONB DEFAULT '{}'::jsonb,
  pseudo_header_order TEXT[] DEFAULT ARRAY[]::TEXT[],
  header_order TEXT[] DEFAULT ARRAY[]::TEXT[],
  session_resumed BOOLEAN,
  raw JSONB DEFAULT '{}'::jsonb,
  created_at TIMESTAMPTZ DEFAULT now()
);

CREATE TABLE IF NOT EXISTS pqp.pqp_transaction_events (
  id BIGSERIAL PRIMARY KEY,
  session_id UUID,
  profile_name TEXT,
  event_type TEXT,
  page TEXT,
  duration_ms INTEGER,
  metadata JSONB DEFAULT '{}'::jsonb,
  created_at TIMESTAMPTZ DEFAULT now()
);

CREATE TABLE IF NOT EXISTS pqp.pqp_profile_aging_events (
  id BIGSERIAL PRIMARY KEY,
  session_id UUID,
  profile_name TEXT,
  cookie_age_ms BIGINT,
  local_storage_age_ms BIGINT,
  indexeddb_age_ms BIGINT,
  service_worker_age_ms BIGINT,
  cache_age_ms BIGINT,
  profile_first_seen_at TIMESTAMPTZ,
  raw JSONB DEFAULT '{}'::jsonb,
  created_at TIMESTAMPTZ DEFAULT now()
);

CREATE TABLE IF NOT EXISTS pqp.pqp_fingerprint_collisions (
  id BIGSERIAL PRIMARY KEY,
  signal_name TEXT NOT NULL,
  signal_value TEXT,
  affected_profiles JSONB DEFAULT '[]'::jsonb,
  created_at TIMESTAMPTZ DEFAULT now()
);

ALTER TABLE pqp.pqp_phase4_score_history
  ADD COLUMN IF NOT EXISTS transaction_score INTEGER,
  ADD COLUMN IF NOT EXISTS population_risk_score INTEGER;
SQL

node <<'NODE'
const fs = require("fs");

const routesFile = "apps/pqp-api/src/phase4/pqpPhase4Routes.ts";
let routes = fs.readFileSync(routesFile, "utf8");

if (!routes.includes("/api/pqp/edge-http-event")) {
  const routeBlock = `
  app.post("/api/pqp/edge-http-event", async (req: any, reply: any) => {
    const b: any = req.body || {};

    await pool.query(
      \`INSERT INTO pqp.pqp_edge_http_events
       (session_id, profile_name, ip, ja3, ja4, tls_version, cipher_suite, sni,
        alpn, http_version, h2_settings, pseudo_header_order, header_order,
        session_resumed, raw)
       VALUES ($1,$2,$3,$4,$5,$6,$7,$8,$9,$10,$11,$12,$13,$14,$15)\`,
      [
        b.sessionId,
        b.profileName,
        b.ip,
        b.ja3,
        b.ja4,
        b.tlsVersion,
        b.cipherSuite,
        b.sni,
        b.alpn,
        b.httpVersion,
        b.h2Settings || {},
        b.pseudoHeaderOrder || [],
        b.headerOrder || [],
        b.sessionResumed ?? null,
        b
      ]
    );

    return reply.send({ ok: true });
  });

  app.post("/api/pqp/transaction-event", async (req: any, reply: any) => {
    const b: any = req.body || {};

    await pool.query(
      \`INSERT INTO pqp.pqp_transaction_events
       (session_id, profile_name, event_type, page, duration_ms, metadata)
       VALUES ($1,$2,$3,$4,$5,$6)\`,
      [b.sessionId, b.profileName, b.eventType, b.page, b.durationMs, b.metadata || {}]
    );

    return reply.send({ ok: true });
  });

  app.post("/api/pqp/profile-aging-event", async (req: any, reply: any) => {
    const b: any = req.body || {};

    await pool.query(
      \`INSERT INTO pqp.pqp_profile_aging_events
       (session_id, profile_name, cookie_age_ms, local_storage_age_ms,
        indexeddb_age_ms, service_worker_age_ms, cache_age_ms,
        profile_first_seen_at, raw)
       VALUES ($1,$2,$3,$4,$5,$6,$7,$8,$9)\`,
      [
        b.sessionId,
        b.profileName,
        b.cookieAgeMs,
        b.localStorageAgeMs,
        b.indexedDbAgeMs,
        b.serviceWorkerAgeMs,
        b.cacheAgeMs,
        b.profileFirstSeenAt || null,
        b
      ]
    );

    return reply.send({ ok: true });
  });
`;

  if (!routes.includes('from "../db/pool.js"') && !routes.includes('from "../db/pool"')) {
    routes = routes.replace(
      /^(import .*;\n)/,
      '$1import { pool } from "../db/pool.js";\n'
    );
  }

  const idx = routes.lastIndexOf("\n}");
  if (idx === -1) throw new Error("Could not find closing brace in pqpPhase4Routes.ts");
  routes = routes.slice(0, idx) + routeBlock + routes.slice(idx);
  fs.writeFileSync(routesFile, routes);
}

const engineFile = "apps/pqp-api/src/phase4/pqpPhase4CapabilityEngine.ts";
let engine = fs.readFileSync(engineFile, "utf8");

if (!engine.includes("async function scoreTransaction")) {
  const helpers = `
async function scoreTransaction(sessionId: string) {
  const q = await pool.query(
    \`SELECT event_type, page, duration_ms, metadata
     FROM pqp.pqp_transaction_events
     WHERE session_id=$1\`,
    [sessionId]
  );

  let score = 100;

  for (const r of q.rows) {
    if (r.event_type === "checkout_submit" && Number(r.duration_ms || 0) < 3000) score -= 25;
    if (r.event_type === "login_submit" && Number(r.duration_ms || 0) < 1000) score -= 20;
    if (r.event_type === "coupon_apply" && Number(r.duration_ms || 0) < 500) score -= 10;
    if (r.event_type === "payment_failed") score -= 15;
    if (r.event_type === "inventory_hold_repeat") score -= 20;
  }

  return Math.max(0, score);
}

async function scorePopulationRisk(profileName: string) {
  const q = await pool.query(
    \`SELECT
      COUNT(*) FILTER (WHERE signal_name='canvas_hash') AS canvas,
      COUNT(*) FILTER (WHERE signal_name='audio_hash') AS audio,
      COUNT(*) FILTER (WHERE signal_name='webgl_renderer') AS webgl,
      COUNT(*) FILTER (WHERE signal_name='ja3') AS ja3,
      COUNT(*) FILTER (WHERE signal_name='ja4') AS ja4
     FROM pqp.pqp_fingerprint_collisions
     WHERE affected_profiles::text ILIKE $1\`,
    [\`%\${profileName || ""}%\`]
  );

  const row = q.rows[0] || {};
  let score = 100;

  if (Number(row.canvas) > 0) score -= 15;
  if (Number(row.audio) > 0) score -= 15;
  if (Number(row.webgl) > 0) score -= 10;
  if (Number(row.ja3) > 0) score -= 20;
  if (Number(row.ja4) > 0) score -= 20;

  return Math.max(0, score);
}

`;

  const exportIdx = engine.indexOf("export async function");
  if (exportIdx === -1) throw new Error("Could not find exported function in capability engine");
  engine = engine.slice(0, exportIdx) + helpers + engine.slice(exportIdx);
}

if (!engine.includes("const transactionScore = await scoreTransaction(sessionId);")) {
  engine = engine.replace(
    /const profileCapabilityScore = Math\.round\([\s\S]*?\);/,
    `const transactionScore = await scoreTransaction(sessionId);
  const populationRiskScore = await scorePopulationRisk(profileName);

  const profileCapabilityScore = Math.round(
    networkScore * 0.16 +
    fingerprintScore * 0.20 +
    behaviorScore * 0.14 +
    challengeScore * 0.14 +
    proxyScore * 0.14 +
    populationScore * 0.08 +
    agingScore * 0.07 +
    transactionScore * 0.04 +
    populationRiskScore * 0.03
  );`
  );
}

engine = engine.replace(
  /agingScore,\n\s*profileCapabilityScore,/g,
  "agingScore,\n    transactionScore,\n    populationRiskScore,\n    profileCapabilityScore,"
);

engine = engine.replace(
  /aging_score,\s*profile_capability_score/g,
  "aging_score, transaction_score, population_risk_score, profile_capability_score"
);

engine = engine.replace(
  /agingScore,\s*profileCapabilityScore/g,
  "agingScore, transactionScore, populationRiskScore, profileCapabilityScore"
);

fs.writeFileSync(engineFile, engine);
NODE

echo "Patch complete. Now run migrations/build/restart."
