import { registerPqpOwnedLabRoutes } from "../labs/pqpOwnedLabRoutes.js";
import { evaluateCoverage } from "../coverage/coverageService.js";
import { evaluateRealCapability } from "../mismatch/mismatchEngine.js";
import { writeEvidenceReport } from "../reports/evidenceReport.js";
import { paidIpIntel } from "../integrations/ipIntel.js";
import { sendPqpAlert } from "../alerts/alertService.js";
import { recordBaselineRun } from "../baselines/baselineService.js";
import { analyzeSessionAging } from "../analyzers/sessionAging.js";
import { analyzeFingerprintUniqueness } from "../analyzers/fingerprintUniqueness.js";
import { enrichIp } from "../enrichers/ipReputation.js";
import { FastifyInstance } from "fastify";
import { z } from "zod";
import { pool } from "../db/pool.js";
import { scorePqp } from "../scoring/masterScore.js";

const fingerprintSchema = z.object({
  sessionId: z.string().uuid(),
  userAgent: z.string().optional(),
  languages: z.array(z.string()).optional(),
  platform: z.string().optional(),
  timezone: z.string().optional(),
  screen: z.object({
    width: z.number().optional(),
    height: z.number().optional(),
    colorDepth: z.number().optional()
  }).optional(),
  hardware: z.object({
    cpuCores: z.number().optional(),
    memory: z.number().optional()
  }).optional(),
  browser: z.object({
    webdriver: z.boolean().optional()
  }).optional(),
  webgl: z.object({
    vendor: z.string().optional(),
    renderer: z.string().optional()
  }).optional(),
  canvasHash: z.string().optional(),
  audioHash: z.string().optional(),
  pluginCount: z.number().optional()
});

export async function pqpRoutes(app: FastifyInstance) {
  await registerPqpOwnedLabRoutes(app);
  app.post("/api/pqp/session/start", async (req, reply) => {
    const body: any = req.body || {};
    const ip =
      req.headers["x-forwarded-for"]?.toString().split(",")[0]?.trim() ||
      req.ip;

    const result = await pool.query(
      `INSERT INTO pqp.pqp_sessions
       (profile_name, client_type, ip_address, user_agent)
       VALUES ($1,$2,$3,$4)
       RETURNING id`,
      [
        body.profileName || null,
        body.clientType || "unknown",
        ip,
        req.headers["user-agent"] || null
      ]
    );

    return reply.send({ sessionId: result.rows[0].id });
  });

  app.post("/api/pqp/edge", async (req, reply) => {
    const body: any = req.body || {};
    const headerNames = Object.keys(req.headers);

    await pool.query(
      `INSERT INTO pqp.pqp_edge_events
       (session_id, ip_address, forwarded_for, http_version, tls_version, alpn,
        ja3_hash, ja4_hash, header_names, header_consistency_score, leak_detected)
       VALUES ($1,$2,$3,$4,$5,$6,$7,$8,$9,$10,$11)`,
      [
        body.sessionId,
        req.ip,
        req.headers["x-forwarded-for"] || null,
        req.raw.httpVersion,
        body.tlsVersion || null,
        body.alpn || null,
        body.ja3Hash || null,
        body.ja4Hash || null,
        headerNames,
        scoreHeaderConsistency(headerNames),
        detectLeak(req.headers)
      ]
    );

    return reply.send({ ok: true });
  });

  app.post("/api/pqp/fingerprint", async (req, reply) => {
    const data = fingerprintSchema.parse(req.body);

    await pool.query(
      `INSERT INTO pqp.pqp_browser_fingerprints
       (session_id, user_agent, languages, platform, timezone,
        screen_width, screen_height, color_depth,
        cpu_cores, device_memory, webdriver_flag,
        canvas_hash, audio_hash, webgl_vendor, webgl_renderer, plugin_count, raw)
       VALUES
       ($1,$2,$3,$4,$5,$6,$7,$8,$9,$10,$11,$12,$13,$14,$15,$16,$17)`,
      [
        data.sessionId,
        data.userAgent || null,
        data.languages || [],
        data.platform || null,
        data.timezone || null,
        data.screen?.width || null,
        data.screen?.height || null,
        data.screen?.colorDepth || null,
        data.hardware?.cpuCores || null,
        data.hardware?.memory || null,
        data.browser?.webdriver ?? null,
        data.canvasHash || null,
        data.audioHash || null,
        data.webgl?.vendor || null,
        data.webgl?.renderer || null,
        data.pluginCount || null,
        data
      ]
    );

    return reply.send({ ok: true });
  });

  app.post("/api/pqp/behavior", async (req, reply) => {
    const body: any = req.body || {};
    const events = Array.isArray(body.events) ? body.events : [];

    for (const event of events) {
      await pool.query(
        `INSERT INTO pqp.pqp_behavior_events
         (session_id, event_time, event_type, x_position, y_position, target_element, metadata)
         VALUES ($1, to_timestamp($2 / 1000.0), $3, $4, $5, $6, $7)`,
        [
          body.sessionId,
          event.timestamp || Date.now(),
          event.eventType,
          event.x ?? null,
          event.y ?? null,
          event.target || null,
          event.metadata || {}
        ]
      );
    }

    return reply.send({ ok: true, inserted: events.length });
  });

  app.post("/api/pqp/challenge", async (req, reply) => {
    const body: any = req.body || {};

    await pool.query(
      `INSERT INTO pqp.pqp_challenge_events
       (session_id, challenge_type, completed_at, outcome, duration_ms)
       VALUES ($1,$2,now(),$3,$4)`,
      [
        body.sessionId,
        body.challengeType || "soft",
        body.outcome || "recorded",
        body.durationMs || null
      ]
    );

    return reply.send({ ok: true });
  });

  app.post("/api/pqp/score/:sessionId", async (req, reply) => {
    const { sessionId } = req.params as any;

    const edge = await pool.query(
      `SELECT *, NULL as user_agent FROM pqp.pqp_edge_events
       WHERE session_id=$1 ORDER BY recorded_at DESC LIMIT 1`,
      [sessionId]
    );

    const fp = await pool.query(
      `SELECT * FROM pqp.pqp_browser_fingerprints
       WHERE session_id=$1 ORDER BY recorded_at DESC LIMIT 1`,
      [sessionId]
    );

    const behavior = await pool.query(
      `SELECT * FROM pqp.pqp_behavior_events
       WHERE session_id=$1 ORDER BY event_time ASC`,
      [sessionId]
    );

    const challenge = await pool.query(
      `SELECT * FROM pqp.pqp_challenge_events
       WHERE session_id=$1 ORDER BY issued_at ASC`,
      [sessionId]
    );

    const score = scorePqp({
      edge: edge.rows[0],
      fingerprint: fp.rows[0],
      behaviorEvents: behavior.rows,
      challengeEvents: challenge.rows
    });

    await pool.query(
      `INSERT INTO pqp.pqp_scores
       (session_id, network_score, browser_score, behavior_score,
        continuity_score, challenge_score, total_score, verdict, fail_reasons)
       VALUES ($1,$2,$3,$4,$5,$6,$7,$8,$9)
       ON CONFLICT (session_id)
       DO UPDATE SET
        network_score=$2,
        browser_score=$3,
        behavior_score=$4,
        continuity_score=$5,
        challenge_score=$6,
        total_score=$7,
        verdict=$8,
        fail_reasons=$9,
        scored_at=now()`,
      [
        sessionId,
        score.networkScore,
        score.browserScore,
        score.behaviorScore,
        score.continuityScore,
        score.challengeScore,
        score.totalScore,
        score.verdict,
        JSON.stringify(score.failReasons)
      ]
    );

    await pool.query(
      `UPDATE pqp.pqp_sessions
       SET total_score=$2, verdict=$3, completed_at=now()
       WHERE id=$1`,
      [sessionId, score.totalScore, score.verdict]
    );

    return reply.send(score);
  });

  app.get("/api/pqp/score/:sessionId", async (req, reply) => {
    const { sessionId } = req.params as any;

    const result = await pool.query(
      `SELECT * FROM pqp.pqp_scores WHERE session_id=$1`,
      [sessionId]
    );

    return reply.send(result.rows[0] || null);
  });

  app.get("/api/pqp/dashboard/summary", async (_req, reply) => {
    const result = await pool.query(`
      SELECT
        count(*)::int as sessions,
        avg(total_score)::numeric(10,2) as avg_score,
        max(total_score)::int as high_score,
        min(total_score)::int as low_score
      FROM pqp.pqp_scores
    `);

    return reply.send(result.rows[0]);
  });

  app.post("/api/pqp/ip-reputation/:sessionId", async (req, reply) => {
    const { sessionId } = req.params as any;

    const session = await pool.query(
      `SELECT ip_address FROM pqp.pqp_sessions WHERE id=$1`,
      [sessionId]
    );

    const ip = session.rows[0]?.ip_address || null;
    const enriched = enrichIp(ip);

    await pool.query(
      `INSERT INTO pqp.pqp_ip_reputation
       (session_id, ip_address, asn, org, country_code, ip_type, reputation_score, risk_reasons)
       VALUES ($1,$2,$3,$4,$5,$6,$7,$8)`,
      [
        sessionId,
        ip,
        enriched.asn || null,
        enriched.org || null,
        enriched.countryCode || null,
        enriched.ipType,
        enriched.reputationScore,
        JSON.stringify(enriched.riskReasons)
      ]
    );

    return reply.send(enriched);
  });

  app.post("/api/pqp/leak-test", async (req, reply) => {
    const body: any = req.body || {};

    await pool.query(
      `INSERT INTO pqp.pqp_leak_tests
       (session_id, test_type, observed_value, expected_value, passed, severity, metadata)
       VALUES ($1,$2,$3,$4,$5,$6,$7)`,
      [
        body.sessionId,
        body.testType,
        body.observedValue || null,
        body.expectedValue || null,
        Boolean(body.passed),
        body.severity || "medium",
        body.metadata || {}
      ]
    );

    return reply.send({ ok: true });
  });

  app.post("/api/pqp/profile-run/start", async (req, reply) => {
    const body: any = req.body || {};

    const result = await pool.query(
      `INSERT INTO pqp.pqp_profile_runs
       (profile_name, provider, proxy_label, client_type, notes)
       VALUES ($1,$2,$3,$4,$5)
       RETURNING run_id`,
      [
        body.profileName || null,
        body.provider || "unknown",
        body.proxyLabel || null,
        body.clientType || "unknown",
        body.notes || null
      ]
    );

    return reply.send({ runId: result.rows[0].run_id });
  });

  app.post("/api/pqp/capsolver-outcome", async (req, reply) => {
    const body: any = req.body || {};

    await pool.query(
      `INSERT INTO pqp.pqp_capsolver_outcomes
       (session_id, challenge_type, provider, mode, outcome, duration_ms, cost_usd, error_code)
       VALUES ($1,$2,$3,$4,$5,$6,$7,$8)`,
      [
        body.sessionId,
        body.challengeType || null,
        body.provider || "approved-test-provider",
        body.mode || "record-only",
        body.outcome || "recorded",
        body.durationMs || null,
        body.costUsd || null,
        body.errorCode || null
      ]
    );

    return reply.send({ ok: true });
  });

  app.post("/api/pqp/fingerprint-uniqueness/:sessionId", async (req, reply) => {
    const { sessionId } = req.params as any;
    return reply.send(await analyzeFingerprintUniqueness(sessionId));
  });

  app.post("/api/pqp/session-aging/:sessionId", async (req, reply) => {
    const { sessionId } = req.params as any;
    return reply.send(await analyzeSessionAging(sessionId));
  });

  app.post("/api/pqp/flow-test", async (req, reply) => {
    const body: any = req.body || {};

    await pool.query(
      `INSERT INTO pqp.pqp_flow_tests
       (session_id, flow_name, flow_step, outcome, duration_ms, risk_score, metadata)
       VALUES ($1,$2,$3,$4,$5,$6,$7)`,
      [
        body.sessionId,
        body.flowName,
        body.flowStep,
        body.outcome,
        body.durationMs || null,
        body.riskScore || 0,
        body.metadata || {}
      ]
    );

    return reply.send({ ok: true });
  });

  app.post("/api/pqp/evidence/:sessionId", async (req, reply) => {
    const { sessionId } = req.params as any;
    return reply.send(await writeEvidenceReport(sessionId));
  });

  app.post("/api/pqp/edge-log-ingest", async (req, reply) => {
    const body: any = req.body || {};

    await pool.query(
      `INSERT INTO pqp.pqp_edge_log_ingest
       (session_id, source, request_id, ip_address, ja3_hash, ja4_hash,
        tls_version, alpn, http_version, header_order, raw)
       VALUES ($1,$2,$3,$4,$5,$6,$7,$8,$9,$10,$11)`,
      [
        body.sessionId,
        body.source || "unknown-edge",
        body.requestId || null,
        body.ipAddress || null,
        body.ja3Hash || null,
        body.ja4Hash || null,
        body.tlsVersion || null,
        body.alpn || null,
        body.httpVersion || null,
        body.headerOrder || [],
        body.raw || {}
      ]
    );

    return reply.send({ ok: true });
  });

  app.post("/api/pqp/paid-ip-intel/:sessionId", async (req, reply) => {
    const { sessionId } = req.params as any;

    const result = await pool.query(
      `SELECT ip_address FROM pqp.pqp_sessions WHERE id=$1`,
      [sessionId]
    );

    const ip = String(result.rows[0]?.ip_address || "");
    const intel = await paidIpIntel(ip);

    await pool.query(
      `INSERT INTO pqp.pqp_ip_reputation
       (session_id, ip_address, asn, org, country_code, ip_type, reputation_score, risk_reasons)
       VALUES ($1,$2,$3,$4,$5,$6,$7,$8)`,
      [
        sessionId,
        ip || null,
        intel.asn || null,
        intel.org || null,
        intel.countryCode || null,
        intel.ipType,
        intel.reputationScore,
        JSON.stringify(intel.riskReasons)
      ]
    );

    return reply.send(intel);
  });

  app.post("/api/pqp/alert/:sessionId", async (req, reply) => {
    const { sessionId } = req.params as any;
    const body: any = req.body || {};
    return reply.send(await sendPqpAlert(
      sessionId,
      body.severity || "medium",
      body.message || "PQP alert"
    ));
  });

  app.post("/api/pqp/baseline/:sessionId", async (req, reply) => {
    const { sessionId } = req.params as any;
    const body: any = req.body || {};
    return reply.send(await recordBaselineRun(
      sessionId,
      body.baselineType || "unknown",
      body.label || "unnamed-run"
    ));
  });

  app.get("/api/pqp/baselines/summary", async (_req, reply) => {
    const result = await pool.query(
      `SELECT * FROM pqp.pqp_longitudinal_summary ORDER BY baseline_type`
    );
    return reply.send(result.rows);
  });


  app.post("/api/pqp/network-proxy-check", async (req, reply) => {
    const b: any = req.body || {};

    await pool.query(
      `INSERT INTO pqp.pqp_network_proxy_checks
       (session_id, ip_reputation_score, abuse_history, blocklist_presence,
        ip_country, ip_city, profile_timezone, profile_language, geo_consistent,
        asn, isp_org, isp_type, tcp_os_signature, tcp_profile_match,
        dns_resolver_ip, dns_resolver_country, dns_leak_detected)
       VALUES ($1,$2,$3,$4,$5,$6,$7,$8,$9,$10,$11,$12,$13,$14,$15,$16,$17)`,
      [
        b.sessionId,
        b.ipReputationScore ?? null,
        JSON.stringify(b.abuseHistory || []),
        b.blocklistPresence ?? null,
        b.ipCountry || null,
        b.ipCity || null,
        b.profileTimezone || null,
        b.profileLanguage || null,
        b.geoConsistent ?? null,
        b.asn || null,
        b.ispOrg || null,
        b.ispType || null,
        b.tcpOsSignature || null,
        b.tcpProfileMatch ?? null,
        b.dnsResolverIp || null,
        b.dnsResolverCountry || null,
        b.dnsLeakDetected ?? null
      ]
    );

    return reply.send({ ok: true });
  });

  app.post("/api/pqp/browser-deep-check", async (req, reply) => {
    const b: any = req.body || {};

    await pool.query(
      `INSERT INTO pqp.pqp_browser_deep_checks
       (session_id, user_agent, sec_ch_ua, client_hints_consistent,
        hardware_concurrency, device_memory, canvas_hash,
        webgl_vendor, webgl_renderer, audio_hash, fonts, battery, media_devices)
       VALUES ($1,$2,$3,$4,$5,$6,$7,$8,$9,$10,$11,$12,$13)`,
      [
        b.sessionId,
        b.userAgent || null,
        b.secChUa || null,
        b.clientHintsConsistent ?? null,
        b.hardwareConcurrency || null,
        b.deviceMemory || null,
        b.canvasHash || null,
        b.webglVendor || null,
        b.webglRenderer || null,
        b.audioHash || null,
        JSON.stringify(b.fonts || []),
        JSON.stringify(b.battery || {}),
        JSON.stringify(b.mediaDevices || [])
      ]
    );

    return reply.send({ ok: true });
  });

  app.post("/api/pqp/execution-check", async (req, reply) => {
    const b: any = req.body || {};

    await pool.query(
      `INSERT INTO pqp.pqp_execution_checks
       (session_id, webdriver_state, chrome_runtime_present, plugins_count,
        chrome_api_consistent, js_pow_duration_ms, rtt_ms,
        behavior_mouse_events, behavior_key_events, behavior_scroll_events,
        behavior_entropy_score)
       VALUES ($1,$2,$3,$4,$5,$6,$7,$8,$9,$10,$11)`,
      [
        b.sessionId,
        b.webdriverState || null,
        b.chromeRuntimePresent ?? null,
        b.pluginsCount ?? null,
        b.chromeApiConsistent ?? null,
        b.jsPowDurationMs ?? null,
        b.rttMs ?? null,
        b.behaviorMouseEvents ?? null,
        b.behaviorKeyEvents ?? null,
        b.behaviorScrollEvents ?? null,
        b.behaviorEntropyScore ?? null
      ]
    );

    return reply.send({ ok: true });
  });

  app.post("/api/pqp/challenge-deep-check", async (req, reply) => {
    const b: any = req.body || {};

    await pool.query(
      `INSERT INTO pqp.pqp_challenge_deep_checks
       (session_id, provider, challenge_type, token_generated_at, token_submitted_at,
        token_freshness_ms, solve_time_ms, fail_count, retry_count,
        final_outcome, cost_usd)
       VALUES ($1,$2,$3,$4,$5,$6,$7,$8,$9,$10,$11)`,
      [
        b.sessionId,
        b.provider || null,
        b.challengeType || null,
        b.tokenGeneratedAt || null,
        b.tokenSubmittedAt || null,
        b.tokenFreshnessMs ?? null,
        b.solveTimeMs ?? null,
        b.failCount ?? 0,
        b.retryCount ?? 0,
        b.finalOutcome || null,
        b.costUsd ?? null
      ]
    );

    return reply.send({ ok: true });
  });

  app.post("/api/pqp/coverage/:sessionId", async (req, reply) => {
    const { sessionId } = req.params as any;
    return reply.send(await evaluateCoverage(sessionId));
  });

  app.get("/api/pqp/coverage/latest/:sessionId", async (req, reply) => {
    const { sessionId } = req.params as any;

    const result = await pool.query(
      `SELECT * FROM pqp.pqp_coverage_results
       WHERE session_id=$1
       ORDER BY created_at DESC
       LIMIT 1`,
      [sessionId]
    );

    return reply.send(result.rows[0] || null);
  });


  app.post("/api/pqp/real-capability/snapshot", async (req, reply) => {
    const b: any = req.body || {};

    await pool.query(
      `INSERT INTO pqp.pqp_real_capability_snapshots
       (session_id, profile_name, proxy_label, snapshot)
       VALUES ($1,$2,$3,$4)`,
      [
        b.sessionId,
        b.profileName || null,
        b.proxyLabel || null,
        b
      ]
    );

    return reply.send({ ok: true });
  });

  app.post("/api/pqp/real-capability/evaluate/:sessionId", async (req, reply) => {
    const { sessionId } = req.params as any;
    return reply.send(await evaluateRealCapability(sessionId));
  });

  app.get("/api/pqp/real-capability/report/:sessionId", async (req, reply) => {
    const { sessionId } = req.params as any;

    const score = await pool.query(
      `SELECT * FROM pqp.pqp_real_capability_scores WHERE session_id=$1`,
      [sessionId]
    );

    const mismatches = await pool.query(
      `SELECT signal_group, signal_name, linode_value, proxy_value,
              browser_value, expected_value, mismatch, severity, reason
       FROM pqp.pqp_mismatch_results
       WHERE session_id=$1
       ORDER BY
        CASE severity
          WHEN 'critical' THEN 1
          WHEN 'high' THEN 2
          WHEN 'medium' THEN 3
          ELSE 4
        END,
        signal_group,
        signal_name`,
      [sessionId]
    );

    return reply.send({
      score: score.rows[0] || null,
      mismatches: mismatches.rows
    });
  });


  app.get("/api/pqp/session-context/:sessionId", async (req, reply) => {
    const { sessionId } = req.params as any;

    const session = await pool.query(
      `SELECT ip_address, profile_name FROM pqp.pqp_sessions WHERE id=$1`,
      [sessionId]
    );

    const observedProxyIp = session.rows[0]?.ip_address || null;
    let proxyIntel: any = {};

    try {
      proxyIntel = observedProxyIp ? await paidIpIntel(String(observedProxyIp)) : {};
    } catch {
      proxyIntel = {};
    }

    return reply.send({
      sessionId,
      profileName: session.rows[0]?.profile_name || null,
      ...(req.headers["x-pqp-internal-report"] === "1" || process.env.PQP_EXPOSE_LINODE_TO_BROWSER === "1" ? {
        linode: {
          ip: process.env.LINODE_IP || null,
          asn: process.env.LINODE_ASN || null,
          city: process.env.LINODE_CITY || null,
          region: process.env.LINODE_REGION || null,
          country: process.env.LINODE_COUNTRY || null
        }
      } : {}),
      proxy: {
        ip: observedProxyIp,
        asn: proxyIntel.asn || null,
        isp: proxyIntel.org || null,
        type: proxyIntel.ipType || null,
        city: proxyIntel.city || null,
        region: proxyIntel.region || null,
        country: proxyIntel.countryCode || null
      }
    });
  });

}

function scoreHeaderConsistency(headerNames: string[]): number {
  const lower = headerNames.map(h => h.toLowerCase());

  let score = 0;

  if (lower.includes("user-agent")) score++;
  if (lower.includes("accept")) score++;
  if (lower.includes("accept-language")) score++;
  if (lower.includes("sec-ch-ua") || lower.includes("sec-fetch-site")) score++;
  if (lower.includes("upgrade-insecure-requests")) score++;

  return score;
}

function detectLeak(headers: Record<string, any>): boolean {
  const leakHeaders = [
    "x-real-ip",
    "x-forwarded-for",
    "forwarded",
    "via",
    "client-ip"
  ];

  return leakHeaders.some(h => Boolean(headers[h]));
}
