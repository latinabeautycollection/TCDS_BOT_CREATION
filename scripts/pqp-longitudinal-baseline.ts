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

async function runBaseline(baselineType: string, label: string, webdriver: boolean, movementCount: number) {
  const session = await post("/api/pqp/session/start", {
    profileName: label,
    clientType: baselineType
  });

  const sessionId = session.sessionId;

  await post("/api/pqp/edge", {
    sessionId,
    ja3Hash: `${baselineType}-ja3-recorded`,
    ja4Hash: `${baselineType}-ja4-recorded`,
    tlsVersion: "TLSv1.3",
    alpn: "h2"
  });

  await post("/api/pqp/fingerprint", {
    sessionId,
    userAgent: `${baselineType}-approved-owned-test`,
    languages: ["en-US"],
    platform: "Win32",
    timezone: "America/New_York",
    screen: { width: 1920, height: 1080, colorDepth: 24 },
    hardware: { cpuCores: 8, memory: 8 },
    browser: { webdriver },
    webgl: { vendor: `${baselineType}-vendor`, renderer: `${baselineType}-renderer` },
    canvasHash: `${baselineType}-canvas-${label}`,
    audioHash: `${baselineType}-audio-${label}`,
    pluginCount: webdriver ? 0 : 5
  });

  const events = Array.from({ length: movementCount }).map((_, i) => ({
    eventType: i % 7 === 0 ? "scroll" : "mousemove",
    timestamp: Date.now() + i * 100,
    x: 150 + i * 4,
    y: 250 + Math.round(Math.sin(i / 3) * 30),
    target: "#baseline",
    metadata: { baselineType }
  }));

  await post("/api/pqp/behavior", { sessionId, events });

  await post("/api/pqp/challenge", {
    sessionId,
    challengeType: "owned_soft_pow",
    outcome: "completed",
    durationMs: webdriver ? 80 : 500
  });

  const score = await post(`/api/pqp/score/${sessionId}`);
  await post(`/api/pqp/baseline/${sessionId}`, { baselineType, label });

  return { sessionId, score };
}

async function main() {
  const results = [];

  results.push(await runBaseline("real_human_baseline", "manual-human-reference", false, 60));
  results.push(await runBaseline("vanilla_automation_baseline", "vanilla-reference", true, 5));
  results.push(await runBaseline("approved_profile_baseline", "approved-profile-reference", false, 40));

  const summaryRes = await fetch(`${base}/api/pqp/baselines/summary`);
  const summary = await summaryRes.json();

  console.log(JSON.stringify({ results, summary }, null, 2));
}

main().catch(err => {
  console.error(err);
  process.exit(1);
});
