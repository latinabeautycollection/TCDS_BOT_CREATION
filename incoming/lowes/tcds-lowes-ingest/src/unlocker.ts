import { config } from "./config.js";
import { fetchWithRetry } from "./http.js";
import { log } from "./log.js";
import { htmlLooks404 } from "./util.js";

export type UnlockResult = {
  url: string;
  zone: string;
  body: string;
  contentType: string;
  status: number;
  pageNotFound: boolean;
};

type UnlockPayload = {
  status_code?: number;
  headers?: Record<string, string | string[]>;
  body?: string;
};

const retryableTargetStatuses = new Set([0, 408, 425, 429, 500, 502, 503, 504]);
const sleep = (ms: number) => new Promise(resolve => setTimeout(resolve, ms));

async function unlock(url: string, zone: string): Promise<UnlockResult> {
  const response = await fetchWithRetry("https://api.brightdata.com/request", {
    method: "POST",
    headers: {
      Authorization: `Bearer ${config.BRIGHT_DATA_API_TOKEN}`,
      "Content-Type": "application/json"
    },
    body: JSON.stringify({
      zone,
      url,
      method: "GET",
      country: config.LOWES_UNLOCKER_COUNTRY,
      format: "json"
    })
  });
  const text = await response.text();
  let payload: UnlockPayload;
  try {
    payload = JSON.parse(text) as UnlockPayload;
  } catch {
    throw new Error(`Lowe's unlocker returned invalid JSON in zone ${zone}`);
  }
  const body = typeof payload.body === "string" ? payload.body : "";
  const status = Number(payload.status_code ?? 0);
  const rawContentType = payload.headers?.["content-type"];
  const contentType = Array.isArray(rawContentType)
    ? rawContentType[0] ?? "text/html"
    : rawContentType ?? "text/html";
  return {
    url,
    zone,
    body,
    contentType,
    status,
    pageNotFound: status === 404 || htmlLooks404(body)
  };
}

export async function unlockLowesPage(url: string): Promise<UnlockResult> {
  const zones = config.LOWES_UNLOCKER_ZONE_POLICY === "premium_only"
    ? [config.BRIGHT_DATA_PREMIUM_UNLOCKER_ZONE]
    : config.LOWES_UNLOCKER_ZONE_POLICY === "standard_only"
      ? [config.BRIGHT_DATA_UNLOCKER_ZONE]
      : [config.BRIGHT_DATA_UNLOCKER_ZONE, config.BRIGHT_DATA_PREMIUM_UNLOCKER_ZONE];
  let last: unknown;
  for (let attempt = 1; attempt <= config.HTTP_MAX_ATTEMPTS; attempt++) {
    for (const zone of zones) {
      try {
        const result = await unlock(url, zone);
        if (result.status === 200 && result.body.trim() && !result.pageNotFound) return result;
        last = new Error(
          `Lowe's unlocker target status ${result.status} with ${result.body.length} body bytes in zone ${zone}`
        );
        if (!retryableTargetStatuses.has(result.status) && result.body.trim()) throw last;
      } catch (error) {
        last = error;
      }
    }
    if (attempt < config.HTTP_MAX_ATTEMPTS) {
      const delay = Math.round(Math.min(120000, 5000 * 2 ** (attempt - 1)) * (0.75 + Math.random() * 0.5));
      log("warn", "lowes_unlocker_retry", { url, attempt, delay, error: String(last) });
      await sleep(delay);
    }
  }
  throw last;
}
