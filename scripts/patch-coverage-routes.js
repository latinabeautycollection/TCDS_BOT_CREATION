const fs = require("fs");
const p = "apps/pqp-api/src/routes/pqp.ts";
let s = fs.readFileSync(p, "utf8");

if (!s.includes("evaluateCoverage")) {
  s = s.replace(
    'import { recordBaselineRun } from "../baselines/baselineService.js";',
    'import { recordBaselineRun } from "../baselines/baselineService.js";\nimport { evaluateCoverage } from "../coverage/coverageService.js";'
  );
}

const insert = `
  app.post("/api/pqp/network-proxy-check", async (req, reply) => {
    const b: any = req.body || {};

    await pool.query(
      \`INSERT INTO pqp_network_proxy_checks
       (session_id, ip_reputation_score, abuse_history, blocklist_presence,
        ip_country, ip_city, profile_timezone, profile_language, geo_consistent,
        asn, isp_org, isp_type, tcp_os_signature, tcp_profile_match,
        dns_resolver_ip, dns_resolver_country, dns_leak_detected)
       VALUES ($1,$2,$3,$4,$5,$6,$7,$8,$9,$10,$11,$12,$13,$14,$15,$16,$17)\`,
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
      \`INSERT INTO pqp_browser_deep_checks
       (session_id, user_agent, sec_ch_ua, client_hints_consistent,
        hardware_concurrency, device_memory, canvas_hash,
        webgl_vendor, webgl_renderer, audio_hash, fonts, battery, media_devices)
       VALUES ($1,$2,$3,$4,$5,$6,$7,$8,$9,$10,$11,$12,$13)\`,
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
      \`INSERT INTO pqp_execution_checks
       (session_id, webdriver_state, chrome_runtime_present, plugins_count,
        chrome_api_consistent, js_pow_duration_ms, rtt_ms,
        behavior_mouse_events, behavior_key_events, behavior_scroll_events,
        behavior_entropy_score)
       VALUES ($1,$2,$3,$4,$5,$6,$7,$8,$9,$10,$11)\`,
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
      \`INSERT INTO pqp_challenge_deep_checks
       (session_id, provider, challenge_type, token_generated_at, token_submitted_at,
        token_freshness_ms, solve_time_ms, fail_count, retry_count,
        final_outcome, cost_usd)
       VALUES ($1,$2,$3,$4,$5,$6,$7,$8,$9,$10,$11)\`,
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
      \`SELECT * FROM pqp_coverage_results
       WHERE session_id=$1
       ORDER BY created_at DESC
       LIMIT 1\`,
      [sessionId]
    );

    return reply.send(result.rows[0] || null);
  });
`;

if (!s.includes("/api/pqp/network-proxy-check")) {
  const idx = s.lastIndexOf("\n}");
  s = s.slice(0, idx) + "\n" + insert + s.slice(idx);
}

fs.writeFileSync(p, s);
