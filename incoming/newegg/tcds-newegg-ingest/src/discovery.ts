export type NeweggDiscoveredProduct = { url: string };

const PRODUCT_ID = /^[A-Z0-9-]{8,}$/i;

export function canonicalizeNeweggProductUrl(value: string, baseUrl: string): string | null {
  try {
    const url = new URL(value.replace(/&amp;/gi, "&"), baseUrl);
    const host = url.hostname.toLowerCase();
    if (url.protocol !== "https:" || (host !== "newegg.com" && !host.endsWith(".newegg.com"))) return null;
    const match = url.pathname.match(/\/p\/([^/]+)\/?$/i);
    if (!match || !PRODUCT_ID.test(match[1]!) || !/\d/.test(match[1]!)) return null;
    url.protocol = "https:";
    url.hostname = "www.newegg.com";
    url.pathname = url.pathname.replace(/\/+$/, "");
    url.search = "";
    url.hash = "";
    return url.href;
  } catch {
    return null;
  }
}

export function extractNeweggProductUrls(html: string, baseUrl: string): string[] {
  const urls = new Set<string>();
  for (const match of html.matchAll(/\bhref=["']([^"']+)["']/gi)) {
    const url = canonicalizeNeweggProductUrl(match[1]!, baseUrl);
    if (url) urls.add(url);
  }
  return [...urls];
}

export async function discoverNeweggProducts(
  seeds: string[], fetchHtml: (url: string) => Promise<string>, limit: number
): Promise<NeweggDiscoveredProduct[]> {
  const urls = new Set<string>();
  for (const seed of seeds) {
    const html = await fetchHtml(seed);
    if (!html.trim()) throw new Error(`NEWEGG_DISCOVERY_EMPTY_RESPONSE:${seed}`);
    for (const url of extractNeweggProductUrls(html, seed)) {
      urls.add(url);
      if (urls.size >= limit) break;
    }
    if (urls.size >= limit) break;
  }
  if (!urls.size) throw new Error("NEWEGG_DISCOVERY_EMPTY");
  return [...urls].slice(0, limit).map(url => ({ url }));
}

export function findUnreturnedNeweggInputs(requested: string[], rows: unknown[]): string[] {
  const returned = new Set<string>();
  for (const value of rows) {
    if (!value || typeof value !== "object") continue;
    const row = value as { input?: { url?: unknown }; url?: unknown };
    const candidate = typeof row.input?.url === "string" ? row.input.url : typeof row.url === "string" ? row.url : null;
    if (!candidate) continue;
    const canonical = canonicalizeNeweggProductUrl(candidate, candidate);
    if (canonical) returned.add(canonical);
  }
  return requested.filter(url => {
    const canonical = canonicalizeNeweggProductUrl(url, url);
    return canonical == null || !returned.has(canonical);
  });
}
