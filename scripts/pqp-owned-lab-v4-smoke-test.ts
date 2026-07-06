const base = process.env.PQP_BASE_URL || "http://127.0.0.1:8088";

async function get(path: string) {
  const r = await fetch(base + path);
  if (!r.ok) throw new Error(`${path} failed ${r.status}: ${await r.text()}`);
  return r.json().catch(() => ({}));
}

async function post(path: string, body: any) {
  const r = await fetch(base + path, {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify(body)
  });
  if (!r.ok) throw new Error(`${path} failed ${r.status}: ${await r.text()}`);
  return r.json().catch(() => ({}));
}

async function main() {
  const html = await fetch(base + "/pqp/pqp/labs/owned-checkout-lab.html");
  if (!html.ok) throw new Error(`owned checkout HTML failed ${html.status}`);

  const session = await post("/api/pqp/session/start", {
    profileName: "owned-lab-v4-smoke",
    clientType: "owned-lab-v4-ci"
  });

  const sessionId = session.sessionId;
  if (!sessionId) throw new Error("Missing sessionId");

  await get("/api/pqp/observed-ip");
  await get("/api/pqp/lab-config");

  await post("/api/pqp/challenge-event", {
    sessionId,
    profileName: "owned-lab-v4-smoke",
    challengeType: "recaptcha_v3",
    provider: "smoke",
    outcome: "smoke_recorded",
    solveTimeMs: 1
  });

  await post("/api/pqp/real-capability/snapshot", {
    sessionId,
    profileName: "owned-lab-v4-smoke",
    graphics: {
      canvas: { hash: "owned-lab-v4-canvas" },
      audio: { hash: "owned-lab-v4-audio" },
      webgl: { unmaskedRenderer: "owned-lab-v4-webgl" },
      webgpu: { info: { vendor: "owned-lab-v4-webgpu" } }
    },
    fonts: { fontCount: 12 },
    edge: { ja3: null, ja4: null },
    checkoutLab: { runId: "owned-lab-v4-ci" }
  });

  await get(`/api/pqp/collision-counts/owned-lab-v4-smoke/${sessionId}?runId=owned-lab-v4-ci`);

  await post("/api/pqp/owned-lab/verify-recaptcha", {
    sessionId,
    profileName: "owned-lab-v4-smoke",
    challengeType: "recaptcha_v3",
    token: "fake-ci-token",
    provider: "smoke",
    solveTimeMs: 1
  });

  console.log("PQP owned lab v4 endpoint smoke test passed");
}

main().catch(err => {
  console.error(err);
  process.exit(1);
});
