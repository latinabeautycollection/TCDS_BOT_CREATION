import { pool } from "../db/pool.js";
import {
  buildPhase4CapabilityScore,
  getPhase4PopulationReport,
  ingestEdgeFingerprintEvent
} from "./pqpPhase4CapabilityEngine.js";

async function saveSnapshot(body: any) {
  await pool.query(
    `INSERT INTO pqp.pqp_real_capability_snapshots
     (session_id, profile_name, proxy_label, snapshot)
     VALUES ($1,$2,$3,$4)`,
    [
      body.sessionId,
      body.profileName || null,
      body.proxyLabel || null,
      body
    ]
  );

  return { ok: true };
}

function clamp(x: number) {
  return Math.max(0, Math.min(100, Math.round(x)));
}

async function analyzeDeepFingerprint(sessionId: string) {
  const snapshots = await pool.query(
    `SELECT profile_name, snapshot
     FROM pqp.pqp_real_capability_snapshots
     WHERE session_id=$1
     ORDER BY created_at DESC`,
    [sessionId]
  );

  const rows = snapshots.rows || [];
  const profileName = rows[0]?.profile_name || rows[0]?.snapshot?.profileName || null;

  const fpjs = rows.find((r: any) => r.snapshot?.fingerprintjs)?.snapshot?.fingerprintjs || null;
  const creep = rows.find((r: any) => r.snapshot?.creepjs)?.snapshot?.creepjs || null;
  const base = rows.find((r: any) => r.snapshot?.navigator || r.snapshot?.graphics || r.snapshot?.timezoneLocale)?.snapshot || {};

  const mismatches: Array<{ signalName: string; severity: string; reason: string; raw?: any }> = [];

  let fingerprintjsScore = 100;
  let creepjsScore = 100;

  if (!fpjs?.visitorId) {
    fingerprintjsScore -= 20;
    mismatches.push({
      signalName: "fingerprintjs.visitor_id_missing",
      severity: "medium",
      reason: "FingerprintJS visitorId missing"
    });
  }

  const fpConfidence = Number(fpjs?.confidence?.score ?? 1);
  if (fpConfidence < 0.8) {
    fingerprintjsScore -= 15;
    mismatches.push({
      signalName: "fingerprintjs.low_confidence",
      severity: "medium",
      reason: "FingerprintJS confidence below threshold",
      raw: { confidence: fpConfidence }
    });
  }

  if (creep?.lies && Array.isArray(creep.lies) && creep.lies.length > 0) {
    creepjsScore -= Math.min(40, creep.lies.length * 10);
    mismatches.push({
      signalName: "creepjs.lies_detected",
      severity: "high",
      reason: "CreepJS reported browser lies",
      raw: { lies: creep.lies }
    });
  }

  const trustScore = Number(creep?.trustScore ?? 100);
  if (trustScore < 80) {
    creepjsScore -= 20;
    mismatches.push({
      signalName: "creepjs.low_trust_score",
      severity: "high",
      reason: "CreepJS trust score below threshold",
      raw: { trustScore }
    });
  }

  const baseTz = base?.timezoneLocale?.browserTimezone;
  const fpTz = fpjs?.components?.timezone?.value;
  if (baseTz && fpTz && baseTz !== fpTz) {
    mismatches.push({
      signalName: "fingerprint.timezone_cross_source_mismatch",
      severity: "high",
      reason: "Base snapshot timezone and FingerprintJS timezone disagree",
      raw: { baseTz, fpTz }
    });
  }

  await pool.query(`DELETE FROM pqp.pqp_deep_fingerprint_mismatches WHERE session_id=$1`, [sessionId]);

  for (const m of mismatches) {
    await pool.query(
      `INSERT INTO pqp.pqp_deep_fingerprint_mismatches
       (session_id, profile_name, signal_name, mismatch, severity, reason, raw)
       VALUES ($1,$2,$3,true,$4,$5,$6)`,
      [sessionId, profileName, m.signalName, m.severity, m.reason, m.raw || {}]
    );
  }

  const populationScore = 90;
  const finalDeepScore = clamp(
    clamp(fingerprintjsScore) * 0.4 +
    clamp(creepjsScore) * 0.4 +
    populationScore * 0.2
  );

  const verdict =
    finalDeepScore >= 90 ? "strong" :
    finalDeepScore >= 75 ? "usable_with_warnings" :
    finalDeepScore >= 60 ? "weak" :
    "fail";

  const detail = {
    fingerprintjsScore: clamp(fingerprintjsScore),
    creepjsScore: clamp(creepjsScore),
    populationScore,
    mismatchCount: mismatches.length
  };

  await pool.query(
    `INSERT INTO pqp.pqp_deep_fingerprint_scores
     (session_id, profile_name, fingerprintjs_score, creepjs_score, population_score,
      final_deep_score, verdict, score_detail)
     VALUES ($1,$2,$3,$4,$5,$6,$7,$8)
     ON CONFLICT (session_id)
     DO UPDATE SET
      profile_name=$2,
      fingerprintjs_score=$3,
      creepjs_score=$4,
      population_score=$5,
      final_deep_score=$6,
      verdict=$7,
      score_detail=$8,
      created_at=now()`,
    [
      sessionId,
      profileName,
      detail.fingerprintjsScore,
      detail.creepjsScore,
      populationScore,
      finalDeepScore,
      verdict,
      detail
    ]
  );

  return {
    sessionId,
    profileName,
    finalDeepScore,
    verdict,
    mismatches
  };
}

export async function registerPqpPhase4Routes(app: any) {
  app.post("/api/pqp/phase4/profile-capability/:sessionId", async (req: any, reply: any) => {
    return reply.send(await buildPhase4CapabilityScore(req.params.sessionId));
  });

  app.get("/api/pqp/phase4/population-report", async (_req: any, reply: any) => {
    return reply.send(await getPhase4PopulationReport());
  });

  app.post("/api/pqp/phase4/edge-fingerprint", async (req: any, reply: any) => {
    return reply.send(await ingestEdgeFingerprintEvent(req.body));
  });

  app.post("/api/pqp/fingerprintjs-result", async (req: any, reply: any) => {
    return reply.send(await saveSnapshot(req.body || {}));
  });

  app.post("/api/pqp/creepjs-result", async (req: any, reply: any) => {
    return reply.send(await saveSnapshot(req.body || {}));
  });

  app.post("/api/pqp/deep-fingerprint/green-tier-analyze/:sessionId", async (req: any, reply: any) => {
    return reply.send(await analyzeDeepFingerprint(req.params.sessionId));
  });

  app.post("/api/pqp/edge-http-event", async (req: any, reply: any) => {
    const b: any = req.body || {};

    await pool.query(
      `INSERT INTO pqp.pqp_edge_http_events
       (session_id, profile_name, ip, ja3, ja4, tls_version, cipher_suite, sni,
        alpn, http_version, h2_settings, pseudo_header_order, header_order,
        session_resumed, raw)
       VALUES ($1,$2,$3,$4,$5,$6,$7,$8,$9,$10,$11::jsonb,$12::jsonb,$13::jsonb,$14,$15::jsonb)`,
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
        JSON.stringify(b.h2Settings || {}),
        JSON.stringify(b.pseudoHeaderOrder || []),
        JSON.stringify(b.headerOrder || []),
        b.sessionResumed ?? null,
        JSON.stringify(b)
      ]
    );

    return reply.send({ ok: true });
  });

  app.post("/api/pqp/transaction-event", async (req: any, reply: any) => {
    const b: any = req.body || {};

    await pool.query(
      `INSERT INTO pqp.pqp_transaction_events
       (session_id, profile_name, event_type, page, duration_ms, metadata)
       VALUES ($1,$2,$3,$4,$5,$6)`,
      [b.sessionId, b.profileName, b.eventType, b.page, b.durationMs, b.metadata || {}]
    );

    return reply.send({ ok: true });
  });

  app.post("/api/pqp/profile-aging-event", async (req: any, reply: any) => {
    const b: any = req.body || {};

    await pool.query(
      `INSERT INTO pqp.pqp_profile_aging_events
       (session_id, profile_name, cookie_age_ms, local_storage_age_ms,
        indexeddb_age_ms, service_worker_age_ms, cache_age_ms,
        profile_first_seen_at, raw)
       VALUES ($1,$2,$3,$4,$5,$6,$7,$8,$9)`,
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

}
