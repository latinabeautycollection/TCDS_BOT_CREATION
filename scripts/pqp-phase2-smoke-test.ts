const base = process.env.PQP_BASE_URL || "http://localhost:8088";

async function post(path: string, body: any = {}) {
  const res = await fetch(`${base}${path}`, {
    method: "POST",
    headers: {"content-type": "application/json"},
    body: JSON.stringify(body)
  });

  const json = await res.json().catch(() => ({}));

  if (!res.ok) {
    throw new Error(`${path} failed ${res.status}: ${JSON.stringify(json)}`);
  }

  return json;
}

async function main() {
  const run = await post("/api/pqp/profile-run/start", {
    profileName: "phase2-approved-test-profile",
    provider: "approved-owned-lab",
    proxyLabel: "residential-proxy-test-label",
    clientType: "approved_internal_test",
    notes: "Phase 2 scoring test only"
  });

  const session = await post("/api/pqp/session/start", {
    profileName: "phase2-approved-test-profile",
    clientType: "approved_internal_test"
  });

  const sessionId = session.sessionId;

  await post("/api/pqp/edge", {
    sessionId,
    ja3Hash: "recorded-ja3-placeholder",
    ja4Hash: "recorded-ja4-placeholder",
    tlsVersion: "TLSv1.3",
    alpn: "h2"
  });

  await post(`/api/pqp/ip-reputation/${sessionId}`);

  await post("/api/pqp/fingerprint", {
    sessionId,
    userAgent: "ApprovedInternalBrowser",
    languages: ["en-US"],
    platform: "Win32",
    timezone: "America/New_York",
    screen: { width: 1920, height: 1080, colorDepth: 24 },
    hardware: { cpuCores: 8, memory: 8 },
    browser: { webdriver: false },
    webgl: { vendor: "ApprovedVendor", renderer: "ApprovedRenderer" },
    canvasHash: "phase2-canvas-hash",
    audioHash: "phase2-audio-hash",
    pluginCount: 5
  });

  await post(`/api/pqp/fingerprint-uniqueness/${sessionId}`);
  await post(`/api/pqp/session-aging/${sessionId}`);

  await post("/api/pqp/leak-test", {
    sessionId,
    testType: "dns_ipv6_webrtc_record",
    observedValue: "no-client-side-leak-observed-in-owned-test",
    expectedValue: "no-leak",
    passed: true,
    severity: "high",
    metadata: {
      dns: "record-only",
      ipv6: "record-only",
      webrtc: "record-only"
    }
  });

  const events = Array.from({ length: 50 }).map((_, i) => ({
    eventType: i % 8 === 0 ? "scroll" : "mousemove",
    timestamp: Date.now() + i * 120,
    x: 200 + i * 5,
    y: 300 + Math.round(Math.sin(i) * 20),
    target: "#phase2",
    metadata: { runId: run.runId }
  }));

  await post("/api/pqp/behavior", { sessionId, events });

  await post("/api/pqp/capsolver-outcome", {
    sessionId,
    challengeType: "owned-test-captcha-or-soft-challenge",
    provider: "approved-test-mode",
    mode: "record-only",
    outcome: "completed",
    durationMs: 4200,
    costUsd: 0
  });

  await post("/api/pqp/challenge", {
    sessionId,
    challengeType: "owned_soft_pow",
    outcome: "completed",
    durationMs: 320
  });

  await post("/api/pqp/flow-test", {
    sessionId,
    flowName: "owned_checkout_simulation",
    flowStep: "cart_to_checkout",
    outcome: "completed",
    durationMs: 5000,
    riskScore: 2,
    metadata: {
      scope: "owned-site-only",
      destructiveActions: false
    }
  });

  const score = await post(`/api/pqp/score/${sessionId}`);
  const evidence = await post(`/api/pqp/evidence/${sessionId}`);

  console.log(JSON.stringify({
    sessionId,
    score,
    evidencePath: evidence.reportPath
  }, null, 2));
}

main().catch(err => {
  console.error(err);
  process.exit(1);
});
