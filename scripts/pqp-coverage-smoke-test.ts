const base = process.env.PQP_BASE_URL || "http://localhost:8088";

async function post(path: string, body: any = {}) {
  const res = await fetch(`${base}${path}`, {
    method: "POST",
    headers: {"content-type":"application/json"},
    body: JSON.stringify(body)
  });
  if (!res.ok) throw new Error(`${path} failed ${res.status}`);
  return res.json();
}

async function main() {
  const s = await post("/api/pqp/session/start", {
    profileName: "coverage-smoke-test",
    clientType: "approved-owned-lab"
  });

  const sessionId = s.sessionId;

  await post("/api/pqp/network-proxy-check", {
    sessionId,
    ipReputationScore: 4,
    abuseHistory: [],
    blocklistPresence: false,
    ipCountry: "US",
    ipCity: "New York",
    profileTimezone: "America/New_York",
    profileLanguage: "en-US",
    geoConsistent: true,
    asn: 12345,
    ispOrg: "Residential ISP Example",
    ispType: "residential",
    tcpOsSignature: "recorded-by-p0f-or-edge",
    tcpProfileMatch: true,
    dnsResolverIp: "resolver-observed",
    dnsResolverCountry: "US",
    dnsLeakDetected: false
  });

  await post("/api/pqp/browser-deep-check", {
    sessionId,
    userAgent: "coverage-test-UA",
    secChUa: '"Chromium";v="126"',
    clientHintsConsistent: true,
    hardwareConcurrency: 8,
    deviceMemory: 8,
    canvasHash: "coverage-canvas",
    webglVendor: "coverage-vendor",
    webglRenderer: "coverage-renderer",
    audioHash: "coverage-audio",
    fonts: ["Arial", "Segoe UI", "Calibri"],
    battery: { level: 0.72, charging: true },
    mediaDevices: [{ kind: "audioinput" }, { kind: "videoinput" }]
  });

  await post("/api/pqp/execution-check", {
    sessionId,
    webdriverState: "false",
    chromeRuntimePresent: true,
    pluginsCount: 5,
    chromeApiConsistent: true,
    jsPowDurationMs: 333,
    rttMs: 42,
    behaviorMouseEvents: 45,
    behaviorKeyEvents: 12,
    behaviorScrollEvents: 6,
    behaviorEntropyScore: 82
  });

  const now = new Date();
  const later = new Date(now.getTime() + 4800);

  await post("/api/pqp/challenge-deep-check", {
    sessionId,
    provider: "capsolver-record-only",
    challengeType: "owned-test-challenge",
    tokenGeneratedAt: now.toISOString(),
    tokenSubmittedAt: later.toISOString(),
    tokenFreshnessMs: 4800,
    solveTimeMs: 3900,
    failCount: 0,
    retryCount: 0,
    finalOutcome: "recorded-success",
    costUsd: 0
  });

  const coverage = await post(`/api/pqp/coverage/${sessionId}`);

  console.log(JSON.stringify({ sessionId, coverage }, null, 2));
}

main().catch(err => {
  console.error(err);
  process.exit(1);
});
