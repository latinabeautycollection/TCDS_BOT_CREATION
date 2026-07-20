export type SamsClubDiscoveredProduct = { url: string };

const PRODUCT_PATH = /\/ip\/[^/]+\/(\d+)\/?$/i;

export function canonicalizeSamsClubProductUrl(value: string, baseUrl: string): string | null {
  try {
    const url = new URL(value.replace(/&amp;/gi, "&"), baseUrl);
    const host = url.hostname.toLowerCase();
    if (url.protocol !== "https:" || (host !== "samsclub.com" && !host.endsWith(".samsclub.com"))) return null;
    if (!PRODUCT_PATH.test(url.pathname)) return null;
    url.protocol = "https:";
    url.hostname = "www.samsclub.com";
    url.pathname = url.pathname.replace(/\/+$/, "");
    url.search = "";
    url.hash = "";
    return url.href;
  } catch {
    return null;
  }
}

export function extractSamsClubProductUrls(html: string, baseUrl: string): string[] {
  const products = new Map<string, string>();
  for (const match of html.matchAll(/"canonicalUrl":"((?:\\.|[^"\\])+)"/gi)) {
    try {
      const decoded = JSON.parse(`"${match[1]}"`) as string;
      const canonical = canonicalizeSamsClubProductUrl(decoded, baseUrl);
      const id = canonical && new URL(canonical).pathname.match(PRODUCT_PATH)?.[1];
      if (canonical && id) products.set(id, canonical);
    } catch {}
  }
  for (const match of html.matchAll(/\bhref=["']([^"']+)["']/gi)) {
    const canonical = canonicalizeSamsClubProductUrl(match[1]!, baseUrl);
    const id = canonical && new URL(canonical).pathname.match(PRODUCT_PATH)?.[1];
    if (canonical && id) products.set(id, canonical);
  }
  return [...products.values()];
}

export async function discoverSamsClubProducts(
  seeds: string[], fetchHtml: (url: string) => Promise<string>, limit: number
): Promise<SamsClubDiscoveredProduct[]> {
  const products = new Map<string, string>();
  for (const seed of seeds) {
    const html = await fetchHtml(seed);
    if (!html.trim()) throw new Error(`SAMSCLUB_DISCOVERY_EMPTY_RESPONSE:${seed}`);
    if (/global adaptive rate limit|rate limit|try again/i.test(html)) throw new Error(`SAMSCLUB_DISCOVERY_RATE_LIMITED:${seed}`);
    for (const url of extractSamsClubProductUrls(html, seed)) {
      const id = new URL(url).pathname.match(PRODUCT_PATH)![1]!;
      products.set(id, url);
      if (products.size >= limit) break;
    }
    if (products.size >= limit) break;
  }
  if (!products.size) throw new Error("SAMSCLUB_DISCOVERY_EMPTY");
  return [...products.values()].slice(0, limit).map(url => ({ url }));
}

export function findUnreturnedSamsClubInputs(requested: string[], rows: unknown[]): string[] {
  const returned = new Set<string>();
  for (const value of rows) {
    if (!value || typeof value !== "object") continue;
    const row = value as { input?: { url?: unknown }; url?: unknown };
    const candidate = typeof row.input?.url === "string" ? row.input.url : typeof row.url === "string" ? row.url : null;
    if (!candidate) continue;
    const canonical = canonicalizeSamsClubProductUrl(candidate, candidate);
    if (canonical) returned.add(canonical);
  }
  return requested.filter(url => {
    const canonical = canonicalizeSamsClubProductUrl(url, url);
    return canonical == null || !returned.has(canonical);
  });
}
