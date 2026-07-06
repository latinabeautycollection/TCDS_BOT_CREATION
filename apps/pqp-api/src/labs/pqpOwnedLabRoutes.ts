import { pool } from "../db/pool.js";
import { pqpTable } from "../fingerprint/pqpTable.js";

const SCHEMA = process.env.PQP_DB_SCHEMA || "pqp";

async function safeInsert(table: string, data: Record<string, any>) {
  const cols = await pool.query(
    `SELECT column_name FROM information_schema.columns WHERE table_schema=$1 AND table_name=$2`,
    [SCHEMA, table]
  );

  const allowed = new Set(cols.rows.map(r => r.column_name));
  const entries = Object.entries(data).filter(([k]) => allowed.has(k));
  if (!entries.length) return { inserted: false };

  await pool.query(
    `INSERT INTO ${pqpTable(table)}
     (${entries.map(([k]) => `"${k}"`).join(",")})
     VALUES (${entries.map((_, i) => `$${i + 1}`).join(",")})`,
    entries.map(([, v]) => v)
  );

  return { inserted: true };
}

function trustedObservedIp(req: any) {
  const trustForwarded = process.env.PQP_TRUST_PROXY_HEADERS === "1";
  const xff = String(req.headers["x-forwarded-for"] || "").split(",")[0].trim();

  if (trustForwarded) {
    return (
      req.headers["cf-connecting-ip"] ||
      req.headers["x-real-ip"] ||
      xff ||
      req.ip ||
      req.socket?.remoteAddress ||
      null
    );
  }

  return req.ip || req.socket?.remoteAddress || null;
}

async function verifyRecaptcha(secret: string, token: string, remoteip?: string) {
  if (!secret || !token) return { success: false, reason: "missing_secret_or_token" };

  const params = new URLSearchParams();
  params.set("secret", secret);
  params.set("response", token);
  if (remoteip) params.set("remoteip", remoteip);

  const res = await fetch("https://www.google.com/recaptcha/api/siteverify", {
    method: "POST",
    headers: { "content-type": "application/x-www-form-urlencoded" },
    body: params
  });

  return res.json();
}

async function lookupCapsolver(taskId?: string) {
  if (!taskId) return null;

  try {
    const q = await pool.query(
      `SELECT * FROM ${pqpTable("pqp_capsolver_events")}
       WHERE task_id=$1
       ORDER BY created_at DESC
       LIMIT 1`,
      [taskId]
    );
    return q.rows[0] || null;
  } catch {
    return null;
  }
}

export async function registerPqpOwnedLabRoutes(app: any) {
  app.get("/api/pqp/lab-config", async (_req: any, reply: any) => {
    return reply.send({
      recaptchaV2SiteKey: process.env.PQP_RECAPTCHA_V2_SITE_KEY || "",
      recaptchaV3SiteKey: process.env.PQP_RECAPTCHA_V3_SITE_KEY || "",
      recaptchaV3Action: "owned_checkout_lab",
      ja3ja4Status: process.env.PQP_EDGE_COLLECTOR_ENABLED === "1" ? "enabled" : "not_enabled",
      stunUrls: (process.env.PQP_STUN_URLS || "").split(",").map(x => x.trim()).filter(Boolean),
      turnUrls: (process.env.PQP_TURN_URLS || "").split(",").map(x => x.trim()).filter(Boolean),
      thirdPartyStunAllowed: process.env.PQP_ALLOW_THIRD_PARTY_STUN === "1"
    });
  });

  app.get("/api/pqp/observed-ip", async (req: any, reply: any) => {
    const ip = trustedObservedIp(req);
    return reply.send({
      ip,
      trustProxyHeaders: process.env.PQP_TRUST_PROXY_HEADERS === "1",
      headersUsed: process.env.PQP_TRUST_PROXY_HEADERS === "1",
      headers: {
        cfConnectingIp: req.headers["cf-connecting-ip"] || null,
        xForwardedFor: req.headers["x-forwarded-for"] || null,
        xRealIp: req.headers["x-real-ip"] || null
      },
      note:
        process.env.PQP_TRUST_PROXY_HEADERS === "1"
          ? "Trusted proxy headers are enabled. Only use this behind controlled NGINX/Cloudflare."
          : "Proxy headers ignored. Using direct req.ip/socket address."
    });
  });

  app.get("/api/pqp/collision-counts/:profileName/:sessionId", async (req: any, reply: any) => {
    const { profileName, sessionId } = req.params;
    const runId = req.query?.runId || null;
    const recentHours = Number(req.query?.recentHours || process.env.PQP_COLLISION_RECENT_HOURS || 24);

    const latest = await pool.query(
      `SELECT snapshot FROM ${pqpTable("pqp_real_capability_snapshots")}
       WHERE session_id=$1 ORDER BY created_at DESC LIMIT 1`,
      [sessionId]
    );

    const snapshot = latest.rows[0]?.snapshot || {};
    const signals: Record<string, any> = {
      canvasHash: snapshot?.graphics?.canvas?.hash || null,
      audioHash: snapshot?.graphics?.audio?.hash || snapshot?.graphics?.audioContextHash || null,
      webglRenderer: snapshot?.graphics?.webgl?.unmaskedRenderer || snapshot?.graphics?.webglRenderer || null,
      webgpuAdapter: snapshot?.graphics?.webgpu?.info?.vendor || null,
      fontCount: snapshot?.fonts?.fontCount || snapshot?.fontsScreen?.fontCount || null,
      ja3: snapshot?.edge?.ja3 || null,
      ja4: snapshot?.edge?.ja4 || null
    };

    async function collision(expr: string, value: any) {
      if (!value) return 0;

      const filters: string[] = [`${expr}=$1`];
      const params: any[] = [String(value)];

      if (runId) {
        params.push(String(runId));
        filters.push(`snapshot->'checkoutLab'->>'runId'=$${params.length}`);
      } else if (recentHours > 0) {
        params.push(recentHours);
        filters.push(`created_at >= now() - ($${params.length}::int || ' hours')::interval`);
      }

      const q = await pool.query(
        `SELECT COUNT(DISTINCT profile_name)::int AS count
         FROM ${pqpTable("pqp_real_capability_snapshots")}
         WHERE ${filters.join(" AND ")}`,
        params
      );
      return q.rows[0]?.count || 0;
    }

    const counts = {
      canvasCollisionCount: await collision(`snapshot->'graphics'->'canvas'->>'hash'`, signals.canvasHash),
      audioCollisionCount: await collision(`COALESCE(snapshot->'graphics'->'audio'->>'hash', snapshot->'graphics'->>'audioContextHash')`, signals.audioHash),
      webglCollisionCount: await collision(`COALESCE(snapshot->'graphics'->'webgl'->>'unmaskedRenderer', snapshot->'graphics'->>'webglRenderer')`, signals.webglRenderer),
      webgpuCollisionCount: await collision(`snapshot->'graphics'->'webgpu'->'info'->>'vendor'`, signals.webgpuAdapter),
      fontCountCollisionCount: await collision(`COALESCE(snapshot->'fonts'->>'fontCount', snapshot->'fontsScreen'->>'fontCount')`, signals.fontCount),
      ja3CollisionCount: await collision(`snapshot->'edge'->>'ja3'`, signals.ja3),
      ja4CollisionCount: await collision(`snapshot->'edge'->>'ja4'`, signals.ja4)
    };

    return reply.send({
      profileName,
      sessionId,
      runId,
      recentHours,
      signals,
      counts,
      ja3ja4Note: "Real JA3/JA4 requires Envoy/OpenResty/Cloudflare edge collection. Browser JavaScript cannot produce true TLS fingerprints."
    });
  });

  app.post("/api/pqp/challenge-event", async (req: any, reply: any) => {
    const b = req.body || {};
    const capsolver = b.capsolver || {};
    const capsolverDb = await lookupCapsolver(capsolver.taskId || b.capsolverTaskId);
    const solverProvider = capsolver.used || capsolverDb ? "capsolver" : (b.provider || "manual_or_unknown");

    await safeInsert("pqp_challenge_events", {
      session_id: b.sessionId,
      profile_name: b.profileName,
      challenge_type: b.challengeType,
      provider: solverProvider,
      solver_provider: solverProvider,
      outcome: b.outcome,
      final_outcome: b.outcome,
      solve_time_ms: b.solveTimeMs,
      solve_ms: b.solveTimeMs,
      retry_count: b.retryCount || capsolver.retryCount || capsolverDb?.retry_count || 0,
      fail_count: b.failCount || 0,
      timeout_count: b.timeoutCount || 0,
      token_generated_at: b.tokenGeneratedAt || null,
      token_submitted_at: b.tokenSubmittedAt || new Date().toISOString(),
      cost_usd: b.costUsd || capsolver.costUsd || capsolverDb?.cost_usd || null,
      cost: b.costUsd || capsolver.costUsd || capsolverDb?.cost_usd || null,
      raw: { ...b, capsolverDb },
      created_at: new Date().toISOString()
    });

    return reply.send({ ok: true, solverProvider, capsolverDbFound: Boolean(capsolverDb) });
  });

  app.post("/api/pqp/owned-lab/verify-recaptcha", async (req: any, reply: any) => {
    const b = req.body || {};
    const remoteip = trustedObservedIp(req);
    const secret =
      b.challengeType === "recaptcha_v3"
        ? process.env.PQP_RECAPTCHA_V3_SECRET_KEY || ""
        : process.env.PQP_RECAPTCHA_V2_SECRET_KEY || "";

    const verification = await verifyRecaptcha(secret, b.token, remoteip);
    const capsolverDb = await lookupCapsolver(b.capsolver?.taskId);
    const solverProvider = b.capsolver?.used || capsolverDb ? "capsolver" : (b.provider || "manual_or_unknown");

    await safeInsert("pqp_challenge_events", {
      session_id: b.sessionId,
      profile_name: b.profileName,
      challenge_type: b.challengeType,
      provider: solverProvider,
      solver_provider: solverProvider,
      outcome: verification.success ? "verified" : "failed_verification",
      final_outcome: verification.success ? "verified" : "failed_verification",
      solve_time_ms: b.solveTimeMs,
      solve_ms: b.solveTimeMs,
      retry_count: b.retryCount || b.capsolver?.retryCount || capsolverDb?.retry_count || 0,
      fail_count: verification.success ? 0 : 1,
      timeout_count: b.timeoutCount || 0,
      token_generated_at: b.tokenGeneratedAt || null,
      token_submitted_at: new Date().toISOString(),
      cost_usd: b.costUsd || b.capsolver?.costUsd || capsolverDb?.cost_usd || null,
      cost: b.costUsd || b.capsolver?.costUsd || capsolverDb?.cost_usd || null,
      raw: { request: b, verification, observedIp: remoteip, capsolver: b.capsolver || null, capsolverDb },
      created_at: new Date().toISOString()
    });

    return reply.send({
      ok: true,
      observedIp: remoteip,
      solverProvider,
      capsolverDbFound: Boolean(capsolverDb),
      verification
    });
  });

  app.post("/api/pqp/behavior-event", async (req: any, reply: any) => {
    const b = req.body || {};
    await safeInsert("pqp_behavior_events", {
      session_id: b.sessionId,
      profile_name: b.profileName,
      event_type: b.eventType,
      payload: b.payload || {},
      created_at: new Date().toISOString()
    });
    return reply.send({ ok: true });
  });

  

  
}
