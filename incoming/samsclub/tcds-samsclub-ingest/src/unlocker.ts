import { config } from "./config.js";
import { fetchWithRetry } from "./http.js";
import { htmlLooks404 } from "./util.js";

export type UnlockResult = { url: string; zone: string; body: string; contentType: string; status: number; pageNotFound: boolean };

async function unlock(url: string, zone: string): Promise<UnlockResult> {
  const response = await fetchWithRetry("https://api.brightdata.com/request", {
    method: "POST",
    headers: { Authorization: `Bearer ${config.BRIGHT_DATA_API_TOKEN}`, "Content-Type": "application/json" },
    body: JSON.stringify({ zone, url, format: "raw" })
  });
  const body = await response.text();
  return {
    url,
    zone,
    body,
    contentType: response.headers.get("content-type") ?? "text/html",
    status: response.status,
    pageNotFound: htmlLooks404(body)
  };
}

export async function unlockSamsClubPage(url: string): Promise<UnlockResult> {
  const zones = config.SAMSCLUB_UNLOCKER_ZONE_POLICY === "premium_only"
    ? [config.BRIGHT_DATA_PREMIUM_UNLOCKER_ZONE]
    : config.SAMSCLUB_UNLOCKER_ZONE_POLICY === "standard_only"
      ? [config.BRIGHT_DATA_UNLOCKER_ZONE]
      : [config.BRIGHT_DATA_UNLOCKER_ZONE, config.BRIGHT_DATA_PREMIUM_UNLOCKER_ZONE];
  let last: unknown;
  for (let attempt = 1; attempt <= 5; attempt++) {
    for (const zone of zones) {
      try {
        const result = await unlock(url, zone);
        const transientBody = /global adaptive rate limit|rate limit|try again/i.test(result.body);
        if (!result.pageNotFound && !transientBody && result.body.trim()) return result;
        last = new Error(`Sam's Club unlocker returned an invalid body in zone ${zone}`);
      } catch (error) {
        last = error;
      }
    }
    if (attempt < 5) await new Promise(resolve => setTimeout(resolve, attempt * 30000));
  }
  throw last;
}
