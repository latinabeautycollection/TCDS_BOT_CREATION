async function pqpHashText(text) {
  const data = new TextEncoder().encode(text);
  const hash = await crypto.subtle.digest("SHA-256", data);
  return [...new Uint8Array(hash)].map(b => b.toString(16).padStart(2, "0")).join("");
}

async function pqpGetBattery() {
  try {
    if (!navigator.getBattery) return {};
    const b = await navigator.getBattery();
    return {
      charging: b.charging,
      chargingTime: b.chargingTime,
      dischargingTime: b.dischargingTime,
      level: b.level
    };
  } catch {
    return {};
  }
}

async function pqpGetMediaDevices() {
  try {
    if (!navigator.mediaDevices?.enumerateDevices) return [];
    const devices = await navigator.mediaDevices.enumerateDevices();
    return devices.map(d => ({
      kind: d.kind,
      labelPresent: Boolean(d.label),
      deviceIdPresent: Boolean(d.deviceId),
      groupIdPresent: Boolean(d.groupId)
    }));
  } catch {
    return [];
  }
}

function pqpGetFontSignals() {
  const fonts = [
    "Arial",
    "Calibri",
    "Cambria",
    "Consolas",
    "Courier New",
    "Georgia",
    "Segoe UI",
    "Tahoma",
    "Times New Roman",
    "Trebuchet MS",
    "Verdana"
  ];

  const base = document.createElement("span");
  base.style.fontSize = "72px";
  base.innerText = "mmmmmmmmmmlli";
  document.body.appendChild(base);

  const results = [];

  for (const font of fonts) {
    base.style.fontFamily = "monospace";
    const mono = base.offsetWidth;

    base.style.fontFamily = `"${font}", monospace`;
    const test = base.offsetWidth;

    if (test !== mono) results.push(font);
  }

  document.body.removeChild(base);
  return results;
}

async function pqpDeepCollect(sessionId) {
  const start = performance.now();
  await fetch("/health");
  const rttMs = Math.round(performance.now() - start);

  const battery = await pqpGetBattery();
  const mediaDevices = await pqpGetMediaDevices();
  const fonts = pqpGetFontSignals();

  const webdriverState =
    navigator.webdriver === undefined ? "undefined" :
    navigator.webdriver === false ? "false" :
    "true";

  const chromeRuntimePresent = Boolean(window.chrome && window.chrome.runtime);
  const pluginsCount = navigator.plugins ? navigator.plugins.length : 0;

  await fetch("/api/pqp/browser-deep-check", {
    method: "POST",
    headers: {"content-type": "application/json"},
    body: JSON.stringify({
      sessionId,
      userAgent: navigator.userAgent,
      secChUa: navigator.userAgentData ? JSON.stringify(navigator.userAgentData.brands || []) : null,
      clientHintsConsistent: true,
      hardwareConcurrency: navigator.hardwareConcurrency || null,
      deviceMemory: navigator.deviceMemory || null,
      canvasHash: window.__pqpCanvasHash || null,
      webglVendor: window.__pqpWebglVendor || null,
      webglRenderer: window.__pqpWebglRenderer || null,
      audioHash: window.__pqpAudioHash || null,
      fonts,
      battery,
      mediaDevices
    })
  });

  await fetch("/api/pqp/execution-check", {
    method: "POST",
    headers: {"content-type": "application/json"},
    body: JSON.stringify({
      sessionId,
      webdriverState,
      chromeRuntimePresent,
      pluginsCount,
      chromeApiConsistent: chromeRuntimePresent || pluginsCount > 0,
      jsPowDurationMs: window.__pqpPowDurationMs || null,
      rttMs,
      behaviorMouseEvents: window.__pqpMouseEvents || 0,
      behaviorKeyEvents: window.__pqpKeyEvents || 0,
      behaviorScrollEvents: window.__pqpScrollEvents || 0,
      behaviorEntropyScore: window.__pqpBehaviorEntropyScore || 0
    })
  });
}
