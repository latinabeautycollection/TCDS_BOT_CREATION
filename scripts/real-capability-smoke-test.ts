const base = process.env.PQP_BASE_URL || "http://localhost:8088";

async function post(path: string, body: any = {}) {
  const res = await fetch(`${base}${path}`, {
    method: "POST",
    headers: {"content-type":"application/json"},
    body: JSON.stringify(body)
  });
  if (!res.ok) throw new Error(`${path} failed ${res.status}: ${await res.text()}`);
  return res.json();
}

async function main() {
  const session = await post("/api/pqp/session/start", {
    profileName: "real-capability-smoke",
    clientType: "owned-lab"
  });

  const sessionId = session.sessionId;

  await post("/api/pqp/real-capability/snapshot", {
    sessionId,
    profileName: "mlx-001",
    proxyLabel: "res-us-ny-001",
    linode: {
      ip: "45.79.1.10",
      asn: "AS63949",
      city: "Ashburn",
      region: "Virginia",
      country: "US"
    },
    proxy: {
      ip: "100.20.30.40",
      asn: "AS701",
      isp: "Verizon Residential",
      type: "residential",
      city: "New York",
      region: "New York",
      country: "US"
    },
    browser: {
      userAgent: "Mozilla/5.0 Windows Chrome",
      clientHints: '"Chromium";v="139"',
      os: "Windows 11",
      cookieEnabled: true,
      serviceWorkers: true
    },
    navigator: {
      webdriver: false,
      language: "en-US",
      languages: ["en-US", "en"],
      platform: "Win32",
      vendor: "Google Inc.",
      hardwareConcurrency: 8,
      deviceMemory: 8,
      maxTouchPoints: 0,
      pluginsCount: 5
    },
    timezoneLocale: {
      browserTimezone: "America/New_York",
      locale: "en-US"
    },
    geolocation: {
      permissionState: "prompt",
      distanceFromProxyKm: 12,
      distanceFromLinodeKm: 360
    },
    mediaDevices: {
      audioInputCount: 1,
      audioOutputCount: 1,
      videoInputCount: 1
    },
    graphics: {
      canvasHash: "canvas-abc",
      webglVendor: "Intel Inc.",
      webglRenderer: "Intel Iris",
      audioContextHash: "audio-abc",
      canvasReuseCount: 1,
      audioReuseCount: 1
    },
    fontsScreen: {
      fonts: ["Arial", "Calibri", "Segoe UI"],
      osExpectedFontMatch: true,
      screenWidth: 1920,
      screenHeight: 1080
    },
    webrtc: {
      candidateIps: ["100.20.30.40"],
      mdnsMasked: false
    },
    networkProtocol: {
      dnsLeakDetected: false,
      ja3: "real-ja3",
      ja4: "real-ja4",
      alpn: "h2",
      httpVersion: "2"
    },
    ports: {
      devToolsExposureIndicator: false,
      unexpectedLocalhostAccess: false
    },
    sessionStability: {
      sessionStartIp: "100.20.30.40",
      sessionEndIp: "100.20.30.40",
      ipChangedDuringSession: false,
      timezoneChangedDuringSession: false,
      uaChangedDuringSession: false,
      webrtcChangedDuringSession: false
    },
    challenge: {
      tokenFreshnessMs: 4000,
      solveTimeMs: 3500,
      retryCount: 0,
      failCount: 0,
      timeoutCount: 0,
      finalOutcome: "recorded-success",
      costUsd: 0
    }
  });

  const result = await post(`/api/pqp/real-capability/evaluate/${sessionId}`);
  console.log(JSON.stringify(result, null, 2));
}

main().catch(err => {
  console.error(err);
  process.exit(1);
});
