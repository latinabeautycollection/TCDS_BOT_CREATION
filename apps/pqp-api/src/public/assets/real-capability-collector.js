async function sha256Text(text) {
  if (window.crypto && crypto.subtle) {
    const data = new TextEncoder().encode(text);
    const hash = await crypto.subtle.digest("SHA-256", data);
    return [...new Uint8Array(hash)].map(b => b.toString(16).padStart(2, "0")).join("");
  }

  // Fallback for non-secure HTTP/IP lab pages where WebCrypto is unavailable.
  let hash = 0;
  for (let i = 0; i < text.length; i++) {
    hash = ((hash << 5) - hash + text.charCodeAt(i)) | 0;
  }
  return "fallback-" + Math.abs(hash).toString(16);
}

function getWebGLDeep() {
  try {
    const canvas = document.createElement("canvas");
    const gl = canvas.getContext("webgl") || canvas.getContext("experimental-webgl");
    if (!gl) return {};
    const dbg = gl.getExtension("WEBGL_debug_renderer_info");
    return {
      webglVendor: dbg ? gl.getParameter(dbg.UNMASKED_VENDOR_WEBGL) : gl.getParameter(gl.VENDOR),
      webglRenderer: dbg ? gl.getParameter(dbg.UNMASKED_RENDERER_WEBGL) : gl.getParameter(gl.RENDERER),
      webglVersion: gl.getParameter(gl.VERSION),
      shaderVersion: gl.getParameter(gl.SHADING_LANGUAGE_VERSION),
      extensions: gl.getSupportedExtensions() || [],
      maxTextureSize: gl.getParameter(gl.MAX_TEXTURE_SIZE),
      viewportDimensions: gl.getParameter(gl.MAX_VIEWPORT_DIMS)
    };
  } catch {
    return {};
  }
}

async function getCanvasHash() {
  const c = document.createElement("canvas");
  c.width = 320;
  c.height = 120;
  const ctx = c.getContext("2d");
  ctx.textBaseline = "top";
  ctx.font = "16px Arial";
  ctx.fillStyle = "#f60";
  ctx.fillRect(10, 10, 100, 40);
  ctx.fillStyle = "#069";
  ctx.fillText("PQP Real Capability Canvas", 12, 16);
  ctx.strokeRect(5, 5, 250, 90);
  return sha256Text(c.toDataURL());
}

async function getAudioHash() {
  try {
    const AC = window.OfflineAudioContext || window.webkitOfflineAudioContext;
    const ctx = new AC(1, 44100, 44100);
    const osc = ctx.createOscillator();
    const comp = ctx.createDynamicsCompressor();
    osc.type = "triangle";
    osc.frequency.value = 10000;
    osc.connect(comp);
    comp.connect(ctx.destination);
    osc.start(0);
    const buffer = await ctx.startRendering();
    const data = buffer.getChannelData(0);
    let sum = 0;
    for (let i = 0; i < data.length; i += 100) sum += Math.abs(data[i]);
    return {
      audioContextHash: await sha256Text(String(sum)),
      audioSampleRate: ctx.sampleRate,
      audioLatency: null
    };
  } catch {
    return {};
  }
}

async function getWebGPU() {
  try {
    if (!navigator.gpu) return { webgpuAvailable: false };
    const adapter = await navigator.gpu.requestAdapter();
    if (!adapter) return { webgpuAvailable: true, adapter: null };
    return {
      webgpuAvailable: true,
      webgpuAdapter: {
        features: Array.from(adapter.features || []),
        limits: adapter.limits || {}
      }
    };
  } catch {
    return { webgpuAvailable: false };
  }
}

function getFonts() {
  const fonts = [
    "Arial","Calibri","Cambria","Consolas","Courier New","Georgia",
    "Helvetica","Menlo","Monaco","Segoe UI","Tahoma","Times New Roman",
    "Trebuchet MS","Verdana","San Francisco"
  ];
  const span = document.createElement("span");
  span.style.fontSize = "72px";
  span.innerText = "mmmmmmmmmmlli";
  document.body.appendChild(span);
  const found = [];
  for (const font of fonts) {
    span.style.fontFamily = "monospace";
    const base = span.offsetWidth;
    span.style.fontFamily = `"${font}", monospace`;
    if (span.offsetWidth !== base) found.push(font);
  }
  document.body.removeChild(span);
  return found;
}

async function getMediaDevicesDeep() {
  try {
    if (!navigator.mediaDevices?.enumerateDevices) return {};
    const devices = await navigator.mediaDevices.enumerateDevices();
    return {
      audioInputCount: devices.filter(d => d.kind === "audioinput").length,
      audioOutputCount: devices.filter(d => d.kind === "audiooutput").length,
      videoInputCount: devices.filter(d => d.kind === "videoinput").length,
      labelsPresent: devices.some(d => Boolean(d.label)),
      deviceIdsPresent: devices.some(d => Boolean(d.deviceId)),
      groupIdsPresent: devices.some(d => Boolean(d.groupId)),
      devices: devices.map(d => ({
        kind: d.kind,
        labelPresent: Boolean(d.label),
        deviceIdPresent: Boolean(d.deviceId),
        groupIdPresent: Boolean(d.groupId)
      }))
    };
  } catch {
    return {};
  }
}

async function getStorage() {
  let quota = null;
  try {
    if (navigator.storage?.estimate) quota = await navigator.storage.estimate();
  } catch {}
  return {
    storageQuota: quota,
    localStorageAvailable: (() => { try { localStorage.setItem("__pqp","1"); localStorage.removeItem("__pqp"); return true; } catch { return false; } })(),
    sessionStorageAvailable: (() => { try { sessionStorage.setItem("__pqp","1"); sessionStorage.removeItem("__pqp"); return true; } catch { return false; } })(),
    indexedDbAvailable: Boolean(window.indexedDB),
    cacheApiAvailable: Boolean(window.caches)
  };
}

async function getPermissions() {
  const names = ["geolocation", "camera", "microphone", "notifications"];
  const out = {};
  for (const name of names) {
    try {
      out[name] = (await navigator.permissions.query({ name })).state;
    } catch {
      out[name] = "unsupported";
    }
  }
  return out;
}

async function getGeo() {
  const permissionState = await (async () => {
    try {
      return (await navigator.permissions.query({ name: "geolocation" })).state;
    } catch {
      return "unknown";
    }
  })();

  return new Promise(resolve => {
    if (!navigator.geolocation) return resolve({ permissionState });
    navigator.geolocation.getCurrentPosition(
      p => resolve({
        permissionState,
        latitude: p.coords.latitude,
        longitude: p.coords.longitude,
        accuracy: p.coords.accuracy,
        altitude: p.coords.altitude,
        heading: p.coords.heading,
        speed: p.coords.speed,
        timestamp: p.timestamp
      }),
      () => resolve({ permissionState }),
      { enableHighAccuracy: false, timeout: 3000, maximumAge: 60000 }
    );
  });
}

async function getWebRTC() {
  return new Promise(resolve => {
    const ips = new Set();
    const protocols = new Set();
    let mdnsMasked = false;

    try {
      const pc = new RTCPeerConnection({ iceServers: [] });
      pc.createDataChannel("pqp");
      pc.onicecandidate = e => {
        if (!e.candidate) {
          pc.close();
          return resolve({
            candidateIps: Array.from(ips),
            candidateProtocols: Array.from(protocols),
            mdnsMasked
          });
        }
        const c = e.candidate.candidate || "";
        if (c.includes(".local")) mdnsMasked = true;
        const parts = c.split(" ");
        if (parts[4]) ips.add(parts[4]);
        if (parts[2]) protocols.add(parts[2]);
      };
      pc.createOffer().then(o => pc.setLocalDescription(o));
      setTimeout(() => {
        try { pc.close(); } catch {}
        resolve({
          candidateIps: Array.from(ips),
          candidateProtocols: Array.from(protocols),
          mdnsMasked
        });
      }, 2500);
    } catch {
      resolve({ candidateIps: [], candidateProtocols: [], mdnsMasked: false });
    }
  });
}

async function collectRealCapabilitySnapshot(sessionId, expected = {}) {
  const canvasHash = await getCanvasHash();
  const webgl = getWebGLDeep();
  const audio = await getAudioHash();
  const webgpu = await getWebGPU();
  const storage = await getStorage();
  const permissions = await getPermissions();
  const mediaDevices = await getMediaDevicesDeep();
  const geolocation = await getGeo();
  const webrtc = await getWebRTC();
  const fonts = getFonts();

  const snapshot = {
    sessionId,
    profileName: expected.profileName || null,
    proxyLabel: expected.proxyLabel || null,

    linode: expected.linode || {},
    proxy: expected.proxy || {},

    browser: {
      userAgent: navigator.userAgent,
      clientHints: navigator.userAgentData ? JSON.stringify(navigator.userAgentData.brands || []) : null,
      browserCore: expected.browserCore || null,
      browserVersion: expected.browserVersion || null,
      platform: navigator.platform,
      os: expected.os || null,
      architecture: expected.architecture || null,
      vendor: navigator.vendor,
      product: navigator.product,
      appVersion: navigator.appVersion,
      doNotTrack: navigator.doNotTrack,
      cookieEnabled: navigator.cookieEnabled,
      pdfViewerEnabled: navigator.pdfViewerEnabled,
      permissions,
      serviceWorkers: Boolean(navigator.serviceWorker),
      ...storage
    },

    navigator: {
      webdriver: navigator.webdriver,
      language: navigator.language,
      languages: navigator.languages ? Array.from(navigator.languages) : [],
      platform: navigator.platform,
      vendor: navigator.vendor,
      hardwareConcurrency: navigator.hardwareConcurrency,
      deviceMemory: navigator.deviceMemory,
      maxTouchPoints: navigator.maxTouchPoints,
      pdfViewerEnabled: navigator.pdfViewerEnabled,
      cookieEnabled: navigator.cookieEnabled,
      pluginsCount: navigator.plugins ? navigator.plugins.length : 0,
      mimeTypesCount: navigator.mimeTypes ? navigator.mimeTypes.length : 0
    },

    timezoneLocale: {
      browserTimezone: Intl.DateTimeFormat().resolvedOptions().timeZone,
      timezoneOffset: new Date().getTimezoneOffset(),
      locale: Intl.DateTimeFormat().resolvedOptions().locale,
      dateFormat: new Intl.DateTimeFormat().format(new Date()),
      numberFormat: new Intl.NumberFormat().format(1234567.89),
      currencyExpectation: expected.currencyExpectation || null
    },

    geolocation,
    mediaDevices,

    graphics: {
      canvasHash,
      canvasEntropy: null,
      ...webgl,
      ...webgpu,
      ...audio,
      canvasReuseCount: expected.canvasReuseCount || 0,
      audioReuseCount: expected.audioReuseCount || 0
    },

    fontsScreen: {
      fonts,
      fontCount: fonts.length,
      osExpectedFontMatch: expected.osExpectedFontMatch ?? null,
      screenWidth: screen.width,
      screenHeight: screen.height,
      availableWidth: screen.availWidth,
      availableHeight: screen.availHeight,
      colorDepth: screen.colorDepth,
      pixelDepth: screen.pixelDepth,
      devicePixelRatio: window.devicePixelRatio,
      windowWidth: window.outerWidth,
      windowHeight: window.outerHeight,
      viewportWidth: window.innerWidth,
      viewportHeight: window.innerHeight
    },

    webrtc,

    networkProtocol: expected.networkProtocol || {},
    ports: expected.ports || {},
    sessionStability: expected.sessionStability || {},
    challenge: expected.challenge || {}
  };

  await fetch("/api/pqp/real-capability/snapshot", {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify(snapshot)
  });

  const res = await fetch("/api/pqp/real-capability/evaluate/" + sessionId, {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify({})
  });

  const json = await res.json().catch(() => ({}));

  if (!res.ok) {
    throw new Error(JSON.stringify(json));
  }

  return json;
}
