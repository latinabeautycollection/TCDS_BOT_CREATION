async function collectFingerprintJS(sessionId) {
  if (!sessionId) throw new Error("sessionId is required");

  const startedAt = Date.now();
  const mod = await import("https://openfpcdn.io/fingerprintjs/v4");
  const fp = await mod.default.load();
  const result = await fp.get();

  const payload = {
    sessionId,
    profileName: new URLSearchParams(location.search).get("profileName") || "forensic-live-profile",
    proxyLabel: "runtime-observed",
    fingerprintjs: {
      visitorId: result.visitorId,
      confidence: result.confidence,
      components: result.components,
      collectedAt: new Date().toISOString(),
      durationMs: Date.now() - startedAt
    }
  };

  const res = await fetch("/api/pqp/real-capability/snapshot", {
    method: "POST",
    headers: {"content-type": "application/json"},
    body: JSON.stringify(payload)
  });

  if (!res.ok) {
    throw new Error("FingerprintJS snapshot POST failed: " + res.status);
  }

  return result;
}

window.collectFingerprintJS = collectFingerprintJS;
