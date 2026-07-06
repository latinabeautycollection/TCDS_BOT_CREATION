const base = process.env.PQP_BASE_URL || "http://127.0.0.1:8088";

async function post(path: string, body: any = {}) {
  const r = await fetch(`${base}${path}`, {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify(body)
  });

  if (!r.ok) {
    throw new Error(`${path} failed ${r.status}: ${await r.text()}`);
  }

  return r.json();
}

async function main() {
  const session = await post("/api/pqp/session/start", {
    profileName: "phase4-4-1-smoke",
    clientType: "phase4-4-1-ci"
  });

  const sessionId = session.sessionId;

  await post("/api/pqp/real-capability/snapshot", {
    sessionId,
    profileName: "phase4-4-1-smoke",
    navigator: { userAgent: "Smoke UA", language: "en-US" },
    timezoneLocale: { browserTimezone: "America/New_York" },
    graphics: {
      canvas: { hash: "phase4-41-canvas" },
      audio: { hash: "phase4-41-audio" },
      webgl: { unmaskedRenderer: "Intel Iris" }
    },
    fonts: { fontCount: 12 },
    storage: { localStorage: true, serviceWorker: true, cookieEnabled: true },
    webrtc: { candidateIps: [], mdnsMasked: true },
    dnsContext: { resolverServers: ["1.1.1.1"] },
    linode: { ip: "198.51.100.10" },
    proxy: { ip: "203.0.113.20", country: "US", timezone: "America/New_York" },
    ipIntel: {
      proxy: {
        ipinfo: { country: "US", timezone: "America/New_York", asn: { type: "isp" } },
        ipqs: { fraud_score: 10, proxy: false, vpn: false, tor: false }
      }
    }
  });

  await post("/api/pqp/phase4/edge-fingerprint", {
    sessionId,
    profileName: "phase4-4-1-smoke",
    ip: "203.0.113.20",
    ja3: "smoke-ja3",
    ja4: "smoke-ja4",
    tlsVersion: "TLSv1.3",
    alpn: "h2",
    httpVersion: "HTTP/2",
    headerOrder: [":method", ":authority", ":scheme", ":path", "user-agent", "accept"]
  });

  await post("/api/pqp/fingerprintjs-result", {
    sessionId,
    profileName: "phase4-4-1-smoke",
    fingerprintjs: {
      visitorId: "phase4-41-fpjs",
      confidence: { score: 0.99 },
      components: {
        userAgent: { value: "Smoke UA" },
        timezone: { value: "America/New_York" }
      }
    }
  });

  await post("/api/pqp/creepjs-result", {
    sessionId,
    profileName: "phase4-4-1-smoke",
    creepjs: {
      trustScore: 95,
      lies: [],
      navigator: { userAgent: "Smoke UA" },
      webgl: { unmaskedRenderer: "Intel Iris" },
      audio: { hash: "phase4-41-audio" },
      canvas: { hash: "phase4-41-canvas" },
      fonts: { fontCount: 12 }
    }
  });

  await post(`/api/pqp/deep-fingerprint/green-tier-analyze/${sessionId}`);
  const score = await post(`/api/pqp/phase4/profile-capability/${sessionId}`);

  if (score.profileCapabilityScore === undefined) {
    throw new Error("Missing Profile Capability Score");
  }

  console.log(JSON.stringify(score, null, 2));
}

main().catch(err => {
  console.error(err);
  process.exit(1);
});
