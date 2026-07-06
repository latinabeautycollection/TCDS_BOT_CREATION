const base = process.env.PQP_BASE_URL || "http://localhost:8088";

async function main() {
  const sessionRes = await fetch(`${base}/api/pqp/session/start`, {
    method: "POST",
    headers: {"content-type": "application/json"},
    body: JSON.stringify({
      profileName: "smoke-test",
      clientType: "approved_internal_test"
    })
  });

  const session = await sessionRes.json();

  await fetch(`${base}/api/pqp/edge`, {
    method: "POST",
    headers: {"content-type": "application/json"},
    body: JSON.stringify({
      sessionId: session.sessionId,
      ja3Hash: "test-ja3",
      ja4Hash: "test-ja4"
    })
  });

  await fetch(`${base}/api/pqp/fingerprint`, {
    method: "POST",
    headers: {"content-type": "application/json"},
    body: JSON.stringify({
      sessionId: session.sessionId,
      userAgent: "SmokeTestBrowser",
      languages: ["en-US"],
      platform: "Linux x86_64",
      timezone: "America/New_York",
      screen: { width: 1920, height: 1080, colorDepth: 24 },
      hardware: { cpuCores: 8, memory: 8 },
      browser: { webdriver: false },
      webgl: { vendor: "TestVendor", renderer: "TestRenderer" },
      canvasHash: "canvas-test",
      audioHash: "audio-test",
      pluginCount: 3
    })
  });

  const events = [];
  for (let i = 0; i < 30; i++) {
    events.push({
      eventType: i % 5 === 0 ? "scroll" : "mousemove",
      timestamp: Date.now() + i,
      x: 100 + i * 3,
      y: 200 + i * 2,
      target: "#smoke",
      metadata: {}
    });
  }

  await fetch(`${base}/api/pqp/behavior`, {
    method: "POST",
    headers: {"content-type": "application/json"},
    body: JSON.stringify({
      sessionId: session.sessionId,
      events
    })
  });

  await fetch(`${base}/api/pqp/challenge`, {
    method: "POST",
    headers: {"content-type": "application/json"},
    body: JSON.stringify({
      sessionId: session.sessionId,
      challengeType: "owned_soft_pow",
      outcome: "completed",
      durationMs: 350
    })
  });

  const scoreRes = await fetch(`${base}/api/pqp/score/${session.sessionId}`, {
    method: "POST"
  });

  const score = await scoreRes.json();

  console.log(JSON.stringify({
    sessionId: session.sessionId,
    score
  }, null, 2));
}

main().catch(err => {
  console.error(err);
  process.exit(1);
});
