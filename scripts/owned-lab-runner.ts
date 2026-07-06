const base = process.env.PQP_BASE_URL || "http://localhost:8088";
const target = process.env.PQP_TARGET_URL || "http://localhost:8089";
const batchSize = Number(process.env.PQP_BATCH_SIZE || 20);
const totalProfiles = Number(process.env.PQP_TOTAL_PROFILES || 20);

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

async function simulateOwnedJourney(profileNumber: number, runId: string) {
  const started = Date.now();
  const profileName = `mlx-profile-${String(profileNumber).padStart(3, "0")}`;
  let sessionId: string | null = null;

  try {
    const session = await post("/api/pqp/session/start", {
      profileName,
      clientType: "multilogin-owned-lab"
    });

    sessionId = session.sessionId;

    await post("/api/pqp/edge", {
      sessionId,
      ja3Hash: `edge-record-placeholder-${profileName}`,
      ja4Hash: `edge-record-placeholder-${profileName}`,
      tlsVersion: "TLSv1.3",
      alpn: "h2"
    });

    await post("/api/pqp/fingerprint", {
      sessionId,
      userAgent: `owned-lab-${profileName}`,
      languages: ["en-US"],
      platform: "Win32",
      timezone: "America/New_York",
      screen: { width: 1920, height: 1080, colorDepth: 24 },
      hardware: { cpuCores: 8, memory: 8 },
      browser: { webdriver: false },
      webgl: { vendor: `vendor-${profileName}`, renderer: `renderer-${profileName}` },
      canvasHash: `canvas-${profileName}`,
      audioHash: `audio-${profileName}`,
      pluginCount: 5
    });

    const events = Array.from({ length: 45 }).map((_, i) => ({
      eventType: i % 9 === 0 ? "scroll" : "mousemove",
      timestamp: Date.now() + i * 111,
      x: 100 + i * 6,
      y: 250 + Math.round(Math.sin(i / 2) * 50),
      target: "#owned-lab",
      metadata: { target, profileName }
    }));

    await post("/api/pqp/behavior", { sessionId, events });

    await post("/api/pqp/capsolver-outcome", {
      sessionId,
      challengeType: "owned-test-challenge",
      provider: "capsolver-record-only",
      mode: "record-only",
      outcome: "not_required_or_recorded",
      durationMs: 0,
      costUsd: 0
    });

    await post("/api/pqp/challenge", {
      sessionId,
      challengeType: "owned_soft_pow",
      outcome: "completed",
      durationMs: 350
    });

    const score = await post(`/api/pqp/score/${sessionId}`);

    await post("/api/pqp/lab/run/result", {
      runId,
      sessionId,
      profileName,
      proxyLabel: `res-proxy-${String(profileNumber).padStart(3, "0")}`,
      reachedHome: true,
      reachedLogin: true,
      reachedProduct: true,
      reachedCart: true,
      reachedCheckout: true,
      challenged: true,
      challengeOutcome: "recorded",
      blocked: false,
      redirected: false,
      finalUrl: `${target}/checkout.html`,
      totalScore: score.totalScore,
      verdict: score.verdict,
      durationMs: Date.now() - started
    });

    return { profileName, ok: true, score: score.totalScore };
  } catch (err: any) {
    await post("/api/pqp/lab/run/result", {
      runId,
      sessionId,
      profileName,
      proxyLabel: `res-proxy-${String(profileNumber).padStart(3, "0")}`,
      blocked: true,
      error: err.message,
      durationMs: Date.now() - started
    });

    return { profileName, ok: false, error: err.message };
  }
}

async function main() {
  const run = await post("/api/pqp/lab/run/start", {
    runName: "multilogin-proxy-capsolver-owned-lab",
    batchSize,
    totalProfiles,
    notes: "Controlled owned-environment PQP lab run"
  });

  const results = [];

  for (let start = 1; start <= totalProfiles; start += batchSize) {
    const end = Math.min(start + batchSize - 1, totalProfiles);
    const batch = [];

    for (let i = start; i <= end; i++) {
      batch.push(simulateOwnedJourney(i, run.runId));
    }

    const batchResults = await Promise.all(batch);
    results.push(...batchResults);

    console.log(`Completed batch ${start}-${end}`);
  }

  await post(`/api/pqp/lab/run/complete/${run.runId}`);

  const summary = await fetch(`${base}/api/pqp/lab/summary`).then(r => r.json());

  console.log(JSON.stringify({ runId: run.runId, results, summary }, null, 2));
}

main().catch(err => {
  console.error(err);
  process.exit(1);
});
