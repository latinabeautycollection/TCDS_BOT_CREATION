import { pool } from "../db/pool.js";

type Mismatch = {
  signalGroup: string;
  signalName: string;
  linodeValue?: any;
  proxyValue?: any;
  browserValue?: any;
  expectedValue?: any;
  mismatch: boolean;
  severity: "critical" | "high" | "medium" | "low";
  reason: string;
};

function text(v: any): string | null {
  if (v === undefined || v === null) return null;
  if (typeof v === "string") return v;
  return JSON.stringify(v);
}

function add(
  list: Mismatch[],
  signalGroup: string,
  signalName: string,
  values: Partial<Mismatch>
) {
  list.push({
    signalGroup,
    signalName,
    linodeValue: values.linodeValue,
    proxyValue: values.proxyValue,
    browserValue: values.browserValue,
    expectedValue: values.expectedValue,
    mismatch: Boolean(values.mismatch),
    severity: values.severity || "low",
    reason: values.reason || ""
  });
}

function countryLanguageExpected(country?: string | null): string {
  if (!country) return "language aligned with proxy country";
  if (country === "US") return "en-US";
  if (country === "GB") return "en-GB";
  if (country === "DO") return "es-DO";
  if (country === "FR") return "fr-FR";
  return "language aligned with proxy country";
}

function expectedTimezone(country?: string | null, region?: string | null): string {
  if (country === "US") {
    if (region?.toLowerCase().includes("new york")) return "America/New_York";
    if (region?.toLowerCase().includes("california")) return "America/Los_Angeles";
    if (region?.toLowerCase().includes("texas")) return "America/Chicago";
    return "US timezone matching proxy region";
  }
  if (country === "DO") return "America/Santo_Domingo";
  if (country === "GB") return "Europe/London";
  if (country === "FR") return "Europe/Paris";
  return "timezone aligned with proxy region";
}

function scoreFromMismatches(mismatches: Mismatch[], group: string): number {
  let score = 100;
  for (const m of mismatches.filter(x => x.signalGroup === group && x.mismatch)) {
    if (m.severity === "critical") score -= 40;
    else if (m.severity === "high") score -= 25;
    else if (m.severity === "medium") score -= 12;
    else score -= 5;
  }
  return Math.max(0, score);
}

export async function evaluateRealCapability(sessionId: string) {
  const snapResult = await pool.query(
    `SELECT * FROM pqp.pqp_real_capability_snapshots
     WHERE session_id=$1 ORDER BY created_at DESC LIMIT 1`,
    [sessionId]
  );

  const row = snapResult.rows[0];
  if (!row) throw new Error("No real capability snapshot found");

  const s = row.snapshot;
  const mismatches: Mismatch[] = [];

  const linode = s.linode || {};
  const proxy = s.proxy || {};
  const browser = s.browser || {};
  const navigator = s.navigator || {};
  const timezone = s.timezoneLocale || {};
  const geo = s.geolocation || {};
  const media = s.mediaDevices || {};
  const graphics = s.graphics || {};
  const fontsScreen = s.fontsScreen || {};
  const webrtc = s.webrtc || {};
  const network = s.networkProtocol || {};
  const ports = s.ports || {};
  const stability = s.sessionStability || {};
  const challenge = s.challenge || {};

  add(mismatches, "browser_attributes", "user_agent", {
    browserValue: browser.userAgent,
    expectedValue: "UA aligned with OS, browser core, and client hints",
    mismatch: Boolean(browser.userAgent && browser.clientHints && !String(browser.clientHints).toLowerCase().includes("chrom") && String(browser.userAgent).toLowerCase().includes("chrome")),
    severity: "high",
    reason: "User-Agent and client hints appear inconsistent"
  });

  add(mismatches, "browser_attributes", "cookies_enabled", {
    browserValue: browser.cookieEnabled,
    expectedValue: true,
    mismatch: browser.cookieEnabled === false,
    severity: "medium",
    reason: "Cookies disabled can be suspicious on commerce/login flows"
  });

  add(mismatches, "browser_attributes", "service_workers", {
    browserValue: browser.serviceWorkers,
    expectedValue: "available/enabled for modern browser",
    mismatch: browser.serviceWorkers === false,
    severity: "medium",
    reason: "Service workers missing or blocked"
  });

  add(mismatches, "navigator", "webdriver", {
    browserValue: navigator.webdriver,
    expectedValue: "false or undefined",
    mismatch: navigator.webdriver === true || navigator.webdriver === "true",
    severity: "critical",
    reason: "navigator.webdriver indicates automation"
  });

  add(mismatches, "navigator", "plugins", {
    browserValue: navigator.pluginsCount,
    expectedValue: "normal modern browser plugin count",
    mismatch: Number(navigator.pluginsCount ?? 0) === 0,
    severity: "medium",
    reason: "Zero plugins can be suspicious depending on browser profile"
  });

  add(mismatches, "timezone_locale", "timezone_vs_proxy", {
    proxyValue: `${proxy.country || ""}/${proxy.region || ""}/${proxy.city || ""}`,
    browserValue: timezone.browserTimezone,
    expectedValue: expectedTimezone(proxy.country, proxy.region || proxy.city),
    mismatch: Boolean(proxy.country && timezone.browserTimezone && !String(timezone.browserTimezone).includes(String(expectedTimezone(proxy.country, proxy.region || proxy.city)).split("/")[0])),
    severity: "high",
    reason: "Browser timezone does not align with proxy country/region"
  });

  add(mismatches, "timezone_locale", "language_vs_proxy", {
    proxyValue: proxy.country,
    browserValue: navigator.language || timezone.locale,
    expectedValue: countryLanguageExpected(proxy.country),
    mismatch: Boolean(proxy.country === "US" && navigator.language && !String(navigator.language).startsWith("en")),
    severity: "medium",
    reason: "Browser language does not align with proxy country"
  });

  add(mismatches, "geolocation", "browser_geo_vs_proxy_city", {
    proxyValue: `${proxy.city || ""}, ${proxy.region || ""}, ${proxy.country || ""}`,
    browserValue: geo.latitude && geo.longitude ? `${geo.latitude},${geo.longitude}, accuracy ${geo.accuracy}` : geo.permissionState,
    expectedValue: "Browser geolocation near proxy city/region when permission is allowed",
    mismatch: Boolean(geo.distanceFromProxyKm && Number(geo.distanceFromProxyKm) > 80),
    severity: "high",
    reason: "Browser geolocation is too far from proxy location"
  });

  add(mismatches, "geolocation", "browser_geo_vs_linode", {
    linodeValue: `${linode.city || ""}, ${linode.region || ""}, ${linode.country || ""}`,
    browserValue: geo.latitude && geo.longitude ? `${geo.latitude},${geo.longitude}` : null,
    expectedValue: "Browser geolocation should not resolve to Linode/server location",
    mismatch: Boolean(geo.distanceFromLinodeKm !== undefined && Number(geo.distanceFromLinodeKm) < 30),
    severity: "critical",
    reason: "Browser geolocation appears close to Linode infrastructure"
  });

  add(mismatches, "media_devices", "media_device_count", {
    browserValue: media,
    expectedValue: "plausible microphone/speaker/camera set for selected OS/browser persona",
    mismatch: Number(media.audioInputCount ?? 0) === 0 && Number(media.videoInputCount ?? 0) === 0,
    severity: "low",
    reason: "No media devices detected"
  });

  add(mismatches, "graphics", "webgl_vendor_renderer", {
    browserValue: `${graphics.webglVendor || ""} / ${graphics.webglRenderer || ""}`,
    expectedValue: "plausible GPU for OS and profile persona",
    mismatch: !graphics.webglVendor || !graphics.webglRenderer,
    severity: "high",
    reason: "Missing WebGL vendor or renderer"
  });

  add(mismatches, "graphics", "canvas_audio_reuse", {
    browserValue: {
      canvasReuseCount: graphics.canvasReuseCount,
      audioReuseCount: graphics.audioReuseCount
    },
    expectedValue: "low reuse across independent profiles",
    mismatch: Number(graphics.canvasReuseCount ?? 0) > 5 || Number(graphics.audioReuseCount ?? 0) > 5,
    severity: "medium",
    reason: "Canvas or AudioContext fingerprint reused across too many profiles"
  });

  add(mismatches, "fonts_screen", "os_font_match", {
    browserValue: fontsScreen.fonts,
    expectedValue: `font set consistent with ${browser.os || navigator.platform}`,
    mismatch: fontsScreen.osExpectedFontMatch === false,
    severity: "medium",
    reason: "Detected font set does not match claimed OS"
  });

  add(mismatches, "fonts_screen", "screen_touch_mismatch", {
    browserValue: {
      width: fontsScreen.screenWidth,
      height: fontsScreen.screenHeight,
      maxTouchPoints: navigator.maxTouchPoints
    },
    expectedValue: "screen and touch capability aligned with UA/platform",
    mismatch: Boolean(String(browser.userAgent || "").toLowerCase().includes("iphone") && Number(fontsScreen.screenWidth) > 1200),
    severity: "high",
    reason: "Mobile UA with desktop-sized screen"
  });

  add(mismatches, "webrtc", "webrtc_proxy_match", {
    linodeValue: linode.ip,
    proxyValue: proxy.ip,
    browserValue: webrtc.candidateIps,
    expectedValue: "WebRTC must not expose Linode/server IP",
    mismatch: Array.isArray(webrtc.candidateIps) && linode.ip && webrtc.candidateIps.includes(linode.ip),
    severity: "critical",
    reason: "WebRTC exposed Linode/server IP"
  });

  add(mismatches, "webrtc", "webrtc_proxy_ip_present", {
    proxyValue: proxy.ip,
    browserValue: webrtc.candidateIps,
    expectedValue: "WebRTC public candidate should align with proxy or be safely masked",
    mismatch: Boolean(proxy.ip && Array.isArray(webrtc.candidateIps) && webrtc.candidateIps.length > 0 && !webrtc.candidateIps.includes(proxy.ip) && webrtc.mdnsMasked !== true),
    severity: "high",
    reason: "WebRTC candidates do not match proxy IP and are not mDNS masked"
  });

  add(mismatches, "network_protocol", "proxy_type", {
    proxyValue: proxy.type,
    expectedValue: "residential or mobile",
    mismatch: ["datacenter", "hosting"].includes(String(proxy.type || "").toLowerCase()),
    severity: "critical",
    reason: "Proxy is classified as datacenter/hosting"
  });

  add(mismatches, "network_protocol", "dns_leak", {
    linodeValue: linode.ip,
    proxyValue: proxy.ip,
    browserValue: network.dnsResolverIp,
    expectedValue: "DNS resolver should align with proxy/ISP region and not Linode",
    mismatch: network.dnsLeakDetected === true,
    severity: "critical",
    reason: "DNS resolver leak detected"
  });

  add(mismatches, "network_protocol", "protocol_presence", {
    browserValue: {
      ja3: network.ja3,
      ja4: network.ja4,
      alpn: network.alpn,
      httpVersion: network.httpVersion
    },
    expectedValue: "JA3/JA4/TLS/ALPN/HTTP version captured from real edge",
    mismatch: !network.ja3 || !network.ja4 || !network.alpn,
    severity: "medium",
    reason: "Missing real edge protocol fingerprint data"
  });

  add(mismatches, "ports", "devtools_or_local_ports", {
    browserValue: ports,
    expectedValue: "no unexpected local automation/debug exposure",
    mismatch: ports.devToolsExposureIndicator === true || ports.unexpectedLocalhostAccess === true,
    severity: "critical",
    reason: "Unexpected local/DevTools exposure detected"
  });

  add(mismatches, "session_stability", "ip_changed_during_session", {
    browserValue: {
      startIp: stability.sessionStartIp,
      endIp: stability.sessionEndIp,
      timeBeforeIpChangeMs: stability.timeBeforeIpChangeMs
    },
    expectedValue: "stable IP during session journey",
    mismatch: stability.ipChangedDuringSession === true,
    severity: "high",
    reason: "IP changed during active session"
  });

  add(mismatches, "session_stability", "identity_changed_during_session", {
    browserValue: {
      timezoneChanged: stability.timezoneChangedDuringSession,
      uaChanged: stability.uaChangedDuringSession,
      webrtcChanged: stability.webrtcChangedDuringSession
    },
    expectedValue: "timezone, UA, and WebRTC stable during session",
    mismatch: stability.timezoneChangedDuringSession === true || stability.uaChangedDuringSession === true || stability.webrtcChangedDuringSession === true,
    severity: "high",
    reason: "Identity attributes changed during session"
  });

  add(mismatches, "challenge", "token_freshness", {
    browserValue: challenge.tokenFreshnessMs,
    expectedValue: "fresh token submitted within owned challenge policy window",
    mismatch: Number(challenge.tokenFreshnessMs ?? 0) > 120000,
    severity: "medium",
    reason: "Challenge token may be stale"
  });

  add(mismatches, "challenge", "retry_fail_ratio", {
    browserValue: {
      retryCount: challenge.retryCount,
      failCount: challenge.failCount,
      timeoutCount: challenge.timeoutCount
    },
    expectedValue: "low retry/fail/timeout count",
    mismatch: Number(challenge.retryCount ?? 0) > 1 || Number(challenge.failCount ?? 0) > 0 || Number(challenge.timeoutCount ?? 0) > 0,
    severity: "high",
    reason: "Challenge flow required retries, failed, or timed out"
  });

  await pool.query(`DELETE FROM pqp.pqp_mismatch_results WHERE session_id=$1`, [sessionId]);

  for (const m of mismatches) {
    await pool.query(
      `INSERT INTO pqp.pqp_mismatch_results
       (session_id, profile_name, proxy_label, signal_group, signal_name,
        linode_value, proxy_value, browser_value, expected_value,
        mismatch, severity, reason)
       VALUES ($1,$2,$3,$4,$5,$6,$7,$8,$9,$10,$11,$12)`,
      [
        sessionId,
        row.profile_name,
        row.proxy_label,
        m.signalGroup,
        m.signalName,
        text(m.linodeValue),
        text(m.proxyValue),
        text(m.browserValue),
        text(m.expectedValue),
        m.mismatch,
        m.severity,
        m.reason
      ]
    );
  }

  const groups = [
    "browser_attributes",
    "navigator",
    "timezone_locale",
    "geolocation",
    "media_devices",
    "graphics",
    "fonts_screen",
    "webrtc",
    "network_protocol",
    "ports",
    "session_stability",
    "challenge"
  ];

  const scores: Record<string, number> = {};
  for (const g of groups) scores[g] = scoreFromMismatches(mismatches, g);

  const finalCapabilityScore = Math.round(groups.reduce((a, g) => a + scores[g], 0) / groups.length);

  const counts = {
    critical: mismatches.filter(m => m.mismatch && m.severity === "critical").length,
    high: mismatches.filter(m => m.mismatch && m.severity === "high").length,
    medium: mismatches.filter(m => m.mismatch && m.severity === "medium").length,
    low: mismatches.filter(m => m.mismatch && m.severity === "low").length
  };

  const verdict =
    counts.critical > 0 ? "critical_mismatch" :
    finalCapabilityScore >= 90 ? "strong" :
    finalCapabilityScore >= 75 ? "usable_with_warnings" :
    finalCapabilityScore >= 60 ? "weak" :
    "fail";

  await pool.query(
    `INSERT INTO pqp.pqp_real_capability_scores
     (session_id, profile_name, proxy_label,
      browser_attribute_score, navigator_score, timezone_locale_score,
      geolocation_score, media_device_score, graphics_score, fonts_screen_score,
      webrtc_score, network_protocol_score, ports_score, session_stability_score,
      challenge_score, final_capability_score,
      critical_count, high_count, medium_count, low_count, verdict)
     VALUES ($1,$2,$3,$4,$5,$6,$7,$8,$9,$10,$11,$12,$13,$14,$15,$16,$17,$18,$19,$20,$21)
     ON CONFLICT (session_id)
     DO UPDATE SET
      browser_attribute_score=$4,
      navigator_score=$5,
      timezone_locale_score=$6,
      geolocation_score=$7,
      media_device_score=$8,
      graphics_score=$9,
      fonts_screen_score=$10,
      webrtc_score=$11,
      network_protocol_score=$12,
      ports_score=$13,
      session_stability_score=$14,
      challenge_score=$15,
      final_capability_score=$16,
      critical_count=$17,
      high_count=$18,
      medium_count=$19,
      low_count=$20,
      verdict=$21,
      created_at=now()`,
    [
      sessionId,
      row.profile_name,
      row.proxy_label,
      scores.browser_attributes,
      scores.navigator,
      scores.timezone_locale,
      scores.geolocation,
      scores.media_devices,
      scores.graphics,
      scores.fonts_screen,
      scores.webrtc,
      scores.network_protocol,
      scores.ports,
      scores.session_stability,
      scores.challenge,
      finalCapabilityScore,
      counts.critical,
      counts.high,
      counts.medium,
      counts.low,
      verdict
    ]
  );

  return {
    sessionId,
    profileName: row.profile_name,
    proxyLabel: row.proxy_label,
    finalCapabilityScore,
    verdict,
    counts,
    scores,
    mismatches: mismatches.filter(m => m.mismatch)
  };
}
