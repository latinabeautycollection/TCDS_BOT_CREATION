import { pool } from "../db/pool.js";
import { pqpTable } from "../fingerprint/pqpTable.js";

const clamp = (x: number) => Math.max(0, Math.min(100, Math.round(x)));
const n = (v: any, f = 0) => Number.isFinite(Number(v)) ? Number(v) : f;

function verdict(score: number) {
  if (score >= 90) return "strong";
  if (score >= 75) return "usable_with_warnings";
  if (score >= 60) return "weak";
  return "fail";
}

function issueScore(rows: any[]) {
  const c = rows.filter(r => r.severity === "critical").length;
  const h = rows.filter(r => r.severity === "high").length;
  const m = rows.filter(r => r.severity === "medium").length;
  const l = rows.filter(r => r.severity === "low").length;
  return clamp(100 - c * 40 - h * 20 - m * 8 - l * 3);
}


async function scoreTransaction(sessionId: string) {
  const q = await pool.query(
    `SELECT event_type, page, duration_ms, metadata
     FROM pqp.pqp_transaction_events
     WHERE session_id=$1`,
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
    `SELECT
      COUNT(*) FILTER (WHERE signal_name='canvas_hash') AS canvas,
      COUNT(*) FILTER (WHERE signal_name='audio_hash') AS audio,
      COUNT(*) FILTER (WHERE signal_name='webgl_renderer') AS webgl,
      COUNT(*) FILTER (WHERE signal_name='ja3') AS ja3,
      COUNT(*) FILTER (WHERE signal_name='ja4') AS ja4
     FROM pqp.pqp_fingerprint_collisions
     WHERE affected_profiles::text ILIKE $1`,
    [`%${profileName || ""}%`]
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

export async function ingestEdgeFingerprintEvent(input: any) {
  const b = input || {};
  await pool.query(
    `INSERT INTO ${pqpTable("pqp_edge_fingerprint_events")}
     (session_id, profile_name, ip, ja3, ja4, tls_version, alpn, http_version, header_order, raw)
     VALUES ($1,$2,$3,$4,$5,$6,$7,$8,$9,$10)`,
    [
      b.sessionId || null,
      b.profileName || null,
      b.ip || null,
      b.ja3 || null,
      b.ja4 || null,
      b.tlsVersion || b.tls_version || null,
      b.alpn || null,
      b.httpVersion || b.http_version || null,
      JSON.stringify(b.headerOrder || b.header_order || []),
      b
    ]
  );
  return { ok: true };
}

export async function buildPhase4CapabilityScore(sessionId: string) {
  const snapQ = await pool.query(
    `SELECT profile_name, snapshot
     FROM ${pqpTable("pqp_real_capability_snapshots")}
     WHERE session_id=$1 ORDER BY created_at DESC LIMIT 1`,
    [sessionId]
  );

  const fpQ = await pool.query(
    `SELECT * FROM ${pqpTable("pqp_deep_fingerprint_scores")}
     WHERE session_id=$1 LIMIT 1`,
    [sessionId]
  );

  const mismatchQ = await pool.query(
    `SELECT severity, signal_name
     FROM ${pqpTable("pqp_deep_fingerprint_mismatches")}
     WHERE session_id=$1 AND mismatch=true`,
    [sessionId]
  );

  const snapshot = snapQ.rows[0]?.snapshot || {};
  const profileName = snapQ.rows[0]?.profile_name || snapshot.profileName || null;
  const mismatches = mismatchQ.rows || [];

  const networkScore = await scoreNetwork(sessionId, snapshot, mismatches);
  const fingerprintScore = n(fpQ.rows[0]?.final_deep_score, issueScore(mismatches));
  const behaviorScore = await scoreBehavior(sessionId);
  const challengeScore = await scoreChallenge(sessionId);
  const proxyScore = scoreProxy(snapshot);
  const populationScore = n(fpQ.rows[0]?.population_score, await scorePopulation(profileName));
  const agingScore = await scoreAging(sessionId, profileName, snapshot);
  const transactionScore = await scoreTransaction(sessionId);
  const populationRiskScore = await scorePopulationRisk(profileName);

  const profileCapabilityScore = clamp(
    networkScore * 0.16 +
    fingerprintScore * 0.20 +
    behaviorScore * 0.14 +
    challengeScore * 0.14 +
    proxyScore * 0.14 +
    populationScore * 0.08 +
    agingScore * 0.07 +
    transactionScore * 0.04 +
    populationRiskScore * 0.03
  );

  const result = {
    sessionId,
    profileName,
    networkScore,
    fingerprintScore,
    behaviorScore,
    challengeScore,
    proxyScore,
    populationScore,
    agingScore,
    transactionScore,
    populationRiskScore,
    profileCapabilityScore,
    verdict: verdict(profileCapabilityScore),
    generatedAt: new Date().toISOString()
  };

  await pool.query(
    `UPDATE ${pqpTable("pqp_real_capability_scores")}
     SET final_capability_score=$2
     WHERE session_id=$1`,
    [sessionId, profileCapabilityScore]
  ).catch(() => null);

  await pool.query(
    `INSERT INTO ${pqpTable("pqp_phase4_score_history")}
     (session_id, profile_name, network_score, fingerprint_score, behavior_score,
      challenge_score, proxy_score, population_score, aging_score, transaction_score, population_risk_score, profile_capability_score, verdict, score_detail)
     VALUES ($1,$2,$3,$4,$5,$6,$7,$8,$9,$10,$11,$12,$13,$14)`,
    [
      sessionId,
      profileName,
      networkScore,
      fingerprintScore,
      behaviorScore,
      challengeScore,
      proxyScore,
      populationScore,
      agingScore,
      transactionScore,
      populationRiskScore,
      profileCapabilityScore,
      result.verdict,
      result
    ]
  ).catch(() => null);

  return result;
}

async function scoreNetwork(sessionId: string, snapshot: any, mismatches: any[]) {
  const edgeQ = await pool.query(
    `SELECT * FROM ${pqpTable("pqp_edge_fingerprint_events")}
     WHERE session_id=$1 ORDER BY created_at DESC LIMIT 1`,
    [sessionId]
  ).catch(() => ({ rows: [] } as any));

  const edge = edgeQ.rows[0] || snapshot.edge || {};
  const networkIssues = mismatches.filter(r =>
    String(r.signal_name || "").startsWith("network.") ||
    String(r.signal_name || "").startsWith("webrtc.") ||
    String(r.signal_name || "").startsWith("proxy_browser.")
  );

  let score = issueScore(networkIssues);

  if (!edge.ja3 && !edge.ja4) score -= 15;
  if (!edge.alpn) score -= 5;
  if (!edge.http_version && !edge.httpVersion) score -= 5;
  if (!snapshot?.dnsContext?.resolverServers) score -= 5;

  const http = String(edge.http_version || edge.httpVersion || "").toLowerCase();
  const alpn = String(edge.alpn || "").toLowerCase();
  if (http.includes("1.1") && alpn.includes("h2")) score -= 10;

  return clamp(score);
}

function scoreProxy(snapshot: any) {
  const ipqs = snapshot?.ipIntel?.proxy?.ipqs || snapshot?.ipIntel?.ipqs || {};
  const ipinfo = snapshot?.ipIntel?.proxy?.ipinfo || snapshot?.ipIntel?.ipinfo || {};
  const proxy = snapshot?.proxy || {};

  let score = 100;
  if (ipqs.proxy || ipqs.vpn || ipqs.tor || ipqs.active_vpn) score -= 25;
  if (n(ipqs.fraud_score) >= 75) score -= 30;
  else if (n(ipqs.fraud_score) >= 50) score -= 15;

  const asType = String(ipinfo?.asn?.type || ipinfo?.as?.type || proxy?.type || "").toLowerCase();
  if (asType.includes("hosting") || asType.includes("datacenter")) score -= 30;
  if (!ipinfo && !proxy?.ip) score -= 15;

  return clamp(score);
}

async function scoreBehavior(sessionId: string) {
  const q = await pool.query(
    `SELECT event_type, payload, created_at
     FROM ${pqpTable("pqp_behavior_events")}
     WHERE session_id=$1 ORDER BY created_at ASC LIMIT 10000`,
    [sessionId]
  ).catch(() => ({ rows: [] } as any));

  const rows = q.rows || [];
  if (!rows.length) return 65;

  const mouse = rows.filter((r: any) => r.event_type === "mousemove");
  const scroll = rows.filter((r: any) => r.event_type === "scroll");
  const key = rows.filter((r: any) => ["keydown", "keyup"].includes(r.event_type));
  const click = rows.filter((r: any) => r.event_type === "click");

  let score = 100;

  if (click.length > 0 && mouse.length === 0) score -= 35;
  if (mouse.length < 10) score -= 15;
  if (scroll.length === 0) score -= 10;
  if (key.length === 0) score -= 5;

  const mouseEntropy = pathEntropy(mouse.map((r: any) => r.payload || {}));
  if (mouse.length >= 10 && mouseEntropy < 0.35) score -= 20;

  const clickTiming = timingStats(click);
  if (clickTiming.minDeltaMs >= 0 && clickTiming.minDeltaMs < 40) score -= 15;
  if (clickTiming.stdDevMs < 25 && click.length >= 4) score -= 10;

  const keyTiming = timingStats(key);
  if (key.length >= 4 && keyTiming.stdDevMs < 20) score -= 10;

  return clamp(score);
}

function pathEntropy(points: any[]) {
  if (points.length < 4) return 0;
  let bends = 0;
  let total = 0;

  for (let i = 2; i < points.length; i++) {
    const a = points[i - 2], b = points[i - 1], c = points[i];
    const dx1 = n(b.x) - n(a.x);
    const dy1 = n(b.y) - n(a.y);
    const dx2 = n(c.x) - n(b.x);
    const dy2 = n(c.y) - n(b.y);
    const cross = Math.abs(dx1 * dy2 - dy1 * dx2);
    const mag = Math.sqrt(dx1 * dx1 + dy1 * dy1) + Math.sqrt(dx2 * dx2 + dy2 * dy2);
    if (mag > 0) {
      total++;
      if (cross / mag > 0.03) bends++;
    }
  }

  return total ? bends / total : 0;
}

function timingStats(rows: any[]) {
  if (rows.length < 2) return { minDeltaMs: -1, stdDevMs: 999 };
  const ts = rows.map((r: any) => new Date(r.created_at).getTime()).filter(Boolean);
  const deltas = [];
  for (let i = 1; i < ts.length; i++) deltas.push(ts[i] - ts[i - 1]);
  const avg = deltas.reduce((a, b) => a + b, 0) / deltas.length;
  const variance = deltas.reduce((a, b) => a + Math.pow(b - avg, 2), 0) / deltas.length;
  return { minDeltaMs: Math.min(...deltas), stdDevMs: Math.sqrt(variance) };
}

async function scoreChallenge(sessionId: string) {
  const q = await pool.query(
    `SELECT * FROM ${pqpTable("pqp_challenge_events")}
     WHERE session_id=$1 ORDER BY created_at DESC LIMIT 100`,
    [sessionId]
  ).catch(() => ({ rows: [] } as any));

  const rows = q.rows || [];
  if (!rows.length) return 85;

  let score = 100;

  for (const r of rows) {
    const outcome = String(r.outcome || r.final_outcome || "").toLowerCase();
    const provider = String(r.provider || r.solver_provider || "").toLowerCase();
    const solveMs = n(r.solve_time_ms || r.solve_ms);
    const retries = n(r.retry_count);
    const failures = n(r.fail_count);
    const cost = n(r.cost_usd || r.cost);

    const tokenGenerated = r.token_generated_at ? new Date(r.token_generated_at).getTime() : 0;
    const tokenSubmitted = r.token_submitted_at ? new Date(r.token_submitted_at).getTime() : 0;
    const freshnessMs = tokenGenerated && tokenSubmitted ? tokenSubmitted - tokenGenerated : null;

    if (outcome.includes("fail") || outcome.includes("timeout")) score -= 25;
    if (solveMs > 45000) score -= 10;
    if (freshnessMs !== null && freshnessMs > 90000) score -= 15;
    if (retries > 1) score -= retries * 5;
    if (failures > 0) score -= failures * 10;
    if (cost > 0.05) score -= 5;
    if (!provider) score -= 3;
  }

  return clamp(score);
}

async function scoreAging(sessionId: string, profileName: string | null, snapshot: any) {
  let score = 100;

  const profileQ = await pool.query(
    `SELECT created_at FROM ${pqpTable("pqp_test_profiles")}
     WHERE profile_name=$1 ORDER BY created_at ASC LIMIT 1`,
    [profileName]
  ).catch(() => ({ rows: [] } as any));

  const firstSessionQ = await pool.query(
    `SELECT MIN(created_at) AS first_seen, MAX(created_at) AS last_seen, COUNT(*)::int AS sessions
     FROM ${pqpTable("pqp_real_capability_snapshots")}
     WHERE profile_name=$1`,
    [profileName]
  ).catch(() => ({ rows: [] } as any));

  const firstSeen = firstSessionQ.rows[0]?.first_seen ? new Date(firstSessionQ.rows[0].first_seen).getTime() : null;
  const sessions = n(firstSessionQ.rows[0]?.sessions);

  if (profileQ.rows.length === 0) score -= 10;
  if (!firstSeen) score -= 10;
  if (sessions < 2) score -= 8;

  const storage = snapshot?.storage || {};
  if (!storage.localStorage) score -= 8;
  if (!storage.serviceWorker) score -= 8;
  if (!storage.cookieEnabled) score -= 15;

  return clamp(score);
}

async function scorePopulation(profileName: string | null) {
  const q = await pool.query(
    `SELECT final_capability_score
     FROM ${pqpTable("pqp_real_capability_scores")}
     WHERE profile_name IS NOT NULL ORDER BY created_at DESC LIMIT 300`
  ).catch(() => ({ rows: [] } as any));

  if (q.rows.length < 10) return 80;

  const ownQ = await pool.query(
    `SELECT final_capability_score
     FROM ${pqpTable("pqp_real_capability_scores")}
     WHERE profile_name=$1 ORDER BY created_at DESC LIMIT 1`,
    [profileName]
  ).catch(() => ({ rows: [] } as any));

  const own = n(ownQ.rows[0]?.final_capability_score, 80);
  const scores = q.rows.map((r: any) => n(r.final_capability_score)).sort((a: number, b: number) => a - b);
  return Math.round((scores.filter((s: number) => s <= own).length / scores.length) * 100);
}

export async function getPhase4PopulationReport() {
  const top = await pool.query(
    `SELECT profile_name, final_capability_score, created_at
     FROM ${pqpTable("pqp_real_capability_scores")}
     ORDER BY final_capability_score DESC NULLS LAST LIMIT 20`
  );

  const worst = await pool.query(
    `SELECT profile_name, final_capability_score, created_at
     FROM ${pqpTable("pqp_real_capability_scores")}
     ORDER BY final_capability_score ASC NULLS LAST LIMIT 20`
  );

  const history = await pool.query(
    `SELECT profile_name, profile_capability_score, network_score, fingerprint_score,
            behavior_score, challenge_score, proxy_score, population_score, aging_score,
            verdict, created_at
     FROM ${pqpTable("pqp_phase4_score_history")}
     ORDER BY created_at DESC LIMIT 100`
  ).catch(() => ({ rows: [] } as any));

  return {
    top20Profiles: top.rows,
    worst20Profiles: worst.rows,
    recentHistory: history.rows
  };
}
